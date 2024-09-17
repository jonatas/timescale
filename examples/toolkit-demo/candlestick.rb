# ruby candlestick.rb postgres://user:pass@host:port/db_name
# @see https://jonatas.github.io/timescaledb/candlestick_tutorial

require 'bundler/inline' #require only what you need

gemfile(true) do
  gem 'timescaledb', path:  '../..'
  gem 'pry'
  gem 'puma'
  gem 'sinatra'
  gem 'sinatra-contrib'
  gem 'sinatra-reloader'
end

ActiveRecord::Base.establish_connection ARGV.first

def db(&block)
  ActiveRecord::Base.logger = Logger.new(STDOUT)
  ActiveRecord::Base.connection.instance_exec(&block)
  ActiveRecord::Base.logger = nil
end

class Tick < ActiveRecord::Base
  extend Timescaledb::ActsAsHypertable
  extend Timescaledb::ActsAsTimeVector
  include Timescaledb:: ContinuousAggregatesHelper

  acts_as_hypertable time_column: "time"
  acts_as_time_vector segment_by: "symbol", value_column: "price"

  scope :ohlcv, -> do
    select("symbol,
            first(price, time) as open,
            max(price) as high,
            min(price) as low,
            last(price, time) as close,
            sum(volume) as volume").group("symbol")
  end
  scope :plotly_candlestick, -> (from: nil) do
    data = all.to_a
    {
      type: 'candlestick',
      xaxis: 'x',
      yaxis: 'y',
      x: data.map(&:time),
      open: data.map(&:open),
      high: data.map(&:high),
      low: data.map(&:low),
      close: data.map(&:close),
      volume: data.map(&:volume)
    }
  end

  continuous_aggregates(
    timeframes: [:minute, :hour, :day, :month],
    scopes: [:ohlcv],
    refresh_policy: {
      minute: { start_offset: "10 minutes", end_offset: "1 minute", schedule_interval: "1 minute" },
      hour:   { start_offset: "4 hour",     end_offset: "1 hour",   schedule_interval: "1 hour" },
      day:    { start_offset: "3 day",      end_offset: "1 day",    schedule_interval: "1 day" },
      month:  { start_offset: "3 month",    end_offset: "1 day",  schedule_interval: "1 day" }
  })

  descendants.each{|e|e.time_vector_options = time_vector_options.merge(value_column: :close)}
end


db do
  if true 
    Tick.drop_continuous_aggregates
    drop_table :ticks, if_exists: true, force: :cascade

    hypertable_options = {
      time_column: "time",
      chunk_time_interval: "1 day",
      compress_segmentby: "symbol",
      compress_orderby: "time",
      compression_interval: "1 week"
    }
    create_table :ticks, id: false, hypertable: hypertable_options, if_not_exists: true do |t|
      t.timestamp :time, null: false
      t.string :symbol, null: false
      t.decimal :price
      t.integer :volume
    end

    add_index :ticks, [:time, :symbol], if_not_exists: true
  end
  execute(ActiveRecord::Base.sanitize_sql_for_conditions( [<<~SQL, {from: 1.week.ago.to_date, to: 1.day.from_now.to_date}]))
    INSERT INTO ticks
    SELECT time, 'SYMBOL', 1 + (random()*30)::int, 100*(random()*10)::int
    FROM generate_series(TIMESTAMP :from,
                    TIMESTAMP :to,
                INTERVAL '10 second') AS time;
     SQL

  Tick.create_continuous_aggregates
  Tick.refresh_aggregates
end


if ARGV.include?("--pry")
  Pry.start
  return
end

require 'sinatra/base'
require "sinatra/json"

class App < Sinatra::Base
  register Sinatra::Reloader

  get '/candlestick.js' do
    send_file 'candlestick.js'
  end
  get '/daily_close_price' do
    json({
      title: "Daily",
      data: Tick::OhlcvPerDay.previous_week.plotly_candlestick
    })
  end
  get '/candlestick_1m' do
    json({
      title: "Candlestick 1 minute last hour",
      data: Tick::OhlcvPerMinute.last_hour.plotly_candlestick
    })
  end

  get '/candlestick_1h' do
    json({
      title: "Candlestick yesterday hourly",
      data:Tick::OhlcvPerHour.yesterday.plotly_candlestick
    })

  end

  get '/candlestick_1d' do
    json({
      title: "Candlestick daily this month",
      data: Tick::OhlcvPerDay.previous_week.plotly_candlestick
    })
  end

  get '/' do
    <<~HTML
      <head>
        <script src="https://cdn.jsdelivr.net/npm/jquery@3.6.1/dist/jquery.min.js"></script>
        <script src='https://cdn.plot.ly/plotly-2.17.1.min.js'></script>
        <script src='/candlestick.js'></script>
      </head>
      <body>
        <div id='charts'>
      </body>
    HTML
  end
end
App.run!
