require 'bundler/inline' #require only what you need

gemfile(true) do 
  gem 'timescaledb', path:  '../..'
  gem 'pry'
  gem 'faker'
end

require 'timescaledb'
require 'pp'
require 'pry'
# ruby all_in_one.rb postgres://user:pass@host:port/db_name
ActiveRecord::Base.establish_connection( ARGV.last)

# Simple example
class Event < ActiveRecord::Base
  extend Timescaledb::ActsAsHypertable
  include Timescaledb::ContinuousAggregatesHelper

  acts_as_hypertable time_column: "time",
    segment_by: "identifier",
    value_column: "cast(payload->>'price' as float)"

  scope :count_clicks, -> { select("count(*)").where(identifier: "click") }
  scope :count_views, -> { select("count(*)").where(identifier: "views") }
  scope :purchase, -> { where(identifier: "purchase") }
  scope :purchase_stats, -> { purchase.select("stats_agg(#{value_column}) as stats_agg") }

  scope :stats, -> { select("average(stats_agg), stddev(stats_agg)") } # just for descendants aggregated classes


  continuous_aggregates scopes: [:count_clicks, :count_views, :purchase_stats],
    timeframes: [:minute, :hour, :day],
    refresh_policy: {
      minute: {
        start_offset: '3 minute',
        end_offset: '1 minute',
        schedule_interval: '1 minute'
      },
      hour: {
        start_offset: '3 hours',
        end_offset: '1 hour',
        schedule_interval: '1 minute'
      },
      day: {
        start_offset: '3 day',
        end_offset: '1 day',
        schedule_interval: '1 minute'
      }
    }
end

# Setup Hypertable as in a migration
ActiveRecord::Base.connection.instance_exec do
  ActiveRecord::Base.logger = Logger.new(STDOUT)

  Event.drop_continuous_aggregates
  drop_table(:events, if_exists: true, cascade: true)

  hypertable_options = {
    time_column: 'time',
    chunk_time_interval: '1 day',
    compress_after: '7 days',
    compress_orderby: 'time',
    compress_segmentby: 'identifier',
  }

  create_table(:events, id: false, hypertable: hypertable_options) do |t|
    t.timestamptz :time, null: false, default: -> { 'now()' }
    t.string :identifier, null: false
    t.jsonb :payload
  end
end


ActiveRecord::Base.connection.instance_exec do
  Event.create_continuous_aggregates
end

# Create some data just to see how it works
1.times do
  Event.transaction do
    Event.create identifier: "sign_up", payload: {"name" => "Eon"}
    Event.create identifier: "login", payload: {"email" => "eon@timescale.com"}
    Event.create identifier: "click", payload: {"user" => "eon", "path" => "/install/timescaledb"}
    Event.create identifier: "scroll", payload: {"user" => "eon", "path" => "/install/timescaledb"}
    Event.create identifier: "logout", payload: {"email" => "eon@timescale.com"}
    Event.create identifier: "purchase", payload: { price: 100.0}
    Event.create identifier: "purchase", payload: { price: 120.0}
    Event.create identifier: "purchase", payload: { price: 140.0}
  end
end


def generate_fake_data(total: 100_000)
  time = 1.month.ago
  total.times.flat_map do
    identifier = %w[sign_up login click scroll logout view purchase]
    time = time + rand(60).seconds
    id = identifier.sample

    payload =  id == "purchase" ? {
      "price" => rand(100..1000)
    } : {
      "name" => Faker::Name.name,
      "email" => Faker::Internet.email,
    }
    {
      time: time,
      identifier: id,
      payload: payload
    }
  end
end

def supress_logs
  ActiveRecord::Base.logger =nil
  yield
  ActiveRecord::Base.logger = Logger.new(STDOUT)
end

batch = generate_fake_data total: 10_000
supress_logs do
  Event.insert_all(batch, returning: false)
end
# Now let's see what we have in the scopes
Event.last_hour.group(:identifier).count # => {"login"=>2, "click"=>1, "logout"=>1, "sign_up"=>1, "scroll"=>1}
Event.refresh_aggregates
pp Event::CountClicksPerMinute.last_hour.map(&:attributes)
pp Event::CountViewsPerMinute.last_hour.map(&:attributes)

puts "compressing 1 chunk of #{ Event.chunks.count } chunks"
Event.chunks.first.compress!

puts "detailed size"
pp Event.hypertable.detailed_size

puts "compression stats"
pp Event.hypertable.compression_stats

puts "decompressing"
Event.chunks.first.decompress!
Pry.start
