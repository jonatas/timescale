# TimescaleDB

> The Timescale SDK for Ruby

A Ruby [gem](https://rubygems.org/gems/timescaledb) for working with TimescaleDB - an open-source time-series database built on PostgreSQL. This gem provides ActiveRecord integration and helpful tools for managing time-series data.

## What is TimescaleDB?

TimescaleDB extends PostgreSQL with specialized features for time-series data:

- **Hypertables**: Automatically partitioned tables optimized for time-series data
- **Hypercores**: Hypercore is a dynamic storage engine that allows you to store data in a way that is optimized for time-series data. Mixing columnar and row-based storage.
- **Chunks**: Transparent table partitions that improve query performance
- **Continuous Aggregates**: Materialized views that automatically update
- **Data Compression**: Automatic compression of older data
- **Data Retention**: Policies for managing data lifecycle

## Installation

Add to your Gemfile:

```ruby
gem 'timescaledb'
```

Or install directly:

```bash
gem install timescaledb
```

## Quick Start

The timescaledb gem provides helpers for creating hypertables, configuring compression, retention policies, and more.
After adding the gem to your Gemfile, you can create hypertables in your migrations.

### 1. Create Hypertables in the Active Record Migrations

```ruby
class CreateEvents < ActiveRecord::Migration[7.0]
  def up
    hypertable_options = {
      time_column: 'created_at',
      chunk_time_interval: '1 day',
      compress_segmentby: 'identifier',
      compress_after: '7 days',
      compress_orderby: 'created_at DESC',
      drop_after: '3 months'
    }

    create_table(:events, id: false, hypertable: hypertable_options) do |t|
      t.timestamptz :created_at
      t.string :identifier, null: false
      t.jsonb :payload
    end
  end

  def down
    drop_table :events
  end
end
```

### 2. Enable TimescaleDB in Your Models

You can enable TimescaleDB in your models by adding the `acts_as_hypertable` macro to your model. This macro extends your existing model with timescaledb-related functionality.

If you are using Rails, you can setup your app to use the gem by creating a `config/initializers/timescaledb.rb` file and adding the following line:

```ruby
# config/initializers/timescaledb.rb
ActiveSupport.on_load(:active_record) { extend Timescaledb::ActsAsHypertable }

# app/models/event.rb
class Event < ActiveRecord::Base
  acts_as_hypertable time_column: "time", segment_by: "identifier"
end
```

**OR** In case you don't want to add it to all your models, you can include it in the model you need:


```ruby
class Event < ActiveRecord::Base
  extend Timescaledb::ActsAsHypertable

  acts_as_hypertable time_column: "time", segment_by: "identifier"
end
```

**OR** create a Hypertable abstract model and inherit from it:

```ruby
class Hypertable < ActiveRecord::Base
  self.abstract_class = true

  extend Timescaledb::ActsAsHypertable
end

# And then, you can inherit from this model:

class Event < Hypertable
  acts_as_hypertable time_column: "time", segment_by: "identifier"
end
```

### Migrations

Create table with the `hypertable` keyword will fully configure the hypertable through the `create_hypertable` function and also fully configure the data lifecycle policies.

#### create_table with `:hypertable`

You can just pass the options to the `hypertable` keyword:

```ruby
hypertable_options = {
  time_column: 'created_at',        # partition data by this column
  chunk_time_interval: '1 day',     # create a new table for each day
  compress_segmentby: 'identifier', # columnar compression key
  compress_after: '7 days',         # start compression after 7 days
  compress_orderby: 'created_at DESC', # compression order
  drop_after: '6 months'            # delete data after 6 months
}

create_table(:events, id: false, hypertable: hypertable_options) do |t|
  t.timestamptz :created_at, null: false
  t.string :identifier, null: false
  t.jsonb :payload
end
```

And the SQL output will be:

```sql
CREATE TABLE events (
  created_at timestamp with time zone NOT NULL,
  identifier text NOT NULL,
  payload jsonb
)
SELECT create_hypertable('events', by_range('created_at', INTERVAL '1 day'));
ALTER TABLE events SET (
  timescaledb.compress,
  timescaledb.compress_segmentby = 'identifier',
  timescaledb.compress_orderby = 'created_at DESC'
);
SELECT add_compression_policy('events', INTERVAL '7 days');
SELECT add_retention_policy('events', INTERVAL '6 months');
```

In this case, the hypertable will be created with the following options:

* [create hypertable](https://docs.timescale.com/api/latest/hypertable/create_hypertable/) for automatic partitioning - 1 table per day.
* [compression](https://docs.timescale.com/api/latest/compression/alter_table_compression/) configured - segment by identifier, this is the column that will be used as a columnar storage key.
* [compression policy](https://docs.timescale.com/api/latest/compression/alter_table_compression/) enabled - partitions with data older than 7 days are compressed.
* [retention policy](https://docs.timescale.com/use-timescale/latest/data-retention/create-a-retention-policy/) configured - 6 months - This is a retention policy that will delete the old data after 6 months. Note this deletion is very efficient as it drops the entire partition.

To understand more about the compression and retention policies, check out the [hypercore article](https://www.timescale.com/blog/hypercore-a-hybrid-row-storage-engine-for-real-time-analytics).


#### Continuous Aggregates

The continuous aggregates allows you to create materialized views that are automatically updated (in background) with the data from the hypertable. You can also set them hierarchically to rollup several timeframes.

This example shows migration to create a continuous aggregate for events per minute:

```ruby
class CreateContinuousAggregates < ActiveRecord::Migration[7.0]
  def up
    query = Event
      .select("time_bucket('1 minute', created_at) as time, identifier, COUNT(*) as count")
      .group("identifier, time")

    create_continuous_aggregate('events_per_minute', query)

    add_continuous_aggregate_policy('events_per_minute',
      start_offset: '3 minute',
      end_offset: '1 minute',
      schedule_interval: '1 minute') 
  end

  def down
    drop_continuous_aggregate :events_per_minute
  end
end
```
Note that you need to establish a policy to refresh the continuous aggregate or refresh it manually.

Alternatively, you can use the `continuous_aggregate` macro in the model to rollup [hierarchically](https://docs.timescale.com/use-timescale/latest/continuous-aggregates/hierarchical-continuous-aggregates/) several timeframes:

```ruby
class Event < ActiveRecord::Base
  extend Timescaledb::ActsAsHypertable
  include Timescaledb::ContinuousAggregatesHelper

  acts_as_hypertable time_column: "time",
    segment_by: "identifier"

  scope :count_clicks, -> { select("count(*)").where(identifier: "click") }
  scope :count_views, -> { select("count(*)").where(identifier: "views") }

  continuous_aggregates scopes: [:count_clicks, :count_views],
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
```

And then in the migration you can create the continuous aggregates:

```ruby
class CreateContinuousAggregates < ActiveRecord::Migration[7.0]
  def up
    Event.create_continuous_aggregates
  end

  def down
    Event.drop_continuous_aggregates
  end
end
```

It will create the continuous aggregates for the given timeframes and scopes and create nested classes for each timeframe.

```ruby
Event.clicks_per_minute # get data from the hypertable
Event::ClicksPerMinute.last_week.all # get data from the continuous aggregate filtered by last week
```

Check the [How to build a better Ruby ORM for time-series and analytics](https://www.timescale.com/blog/building-a-better-ruby-orm-for-time-series-and-analytics) for more details.


#### Scenic integration

The [Scenic](https://github.com/scenic-views/scenic) gem is an easy way to
manage database view definitions for a Rails application. TimescaleDB's
continuous aggregates are more complex than regular PostgreSQL views, and
the schema dumper included with Scenic can't dump a complete definition.

This gem automatically configures Scenic to use a `Timescaledb::Scenic::Adapter`
which will correctly handle schema dumping.

### Compression policy

Compression policy is used to compress data in a hypertable. You can enable the compression policy for a hypertable by using the `add_compression_policy` function.

```ruby
class AddCompressionPolicy < ActiveRecord::Migration[7.0]
  def up
    add_compression_policy('events', INTERVAL '7 days')
  end

  def down
    remove_compression_policy('events')
  end
end
```

### Retention policy

Retention policy is used to delete data (entire partitions) from a hypertable after a certain period of time.
You can enable the retention policy for a hypertable by using the `add_retention_policy` function.

```ruby
class AddRetentionPolicy < ActiveRecord::Migration[7.0]
  def up
    add_retention_policy('events', INTERVAL '6 months')
  end

  def down
    remove_retention_policy('events')
  end
end
```

### Chunks

To get all the chunks from a model's hypertable, you can use `.chunks`.

```ruby
Event.chunks # => [#<Timescaledb::Chunk>, ...]
```

### Hypertable metadata

To get the models' hypertable metadata, you can use `.hypertable`.

```ruby
Event.hypertable # => #<Timescaledb::Hypertable>
```

To get hypertable metadata for all hypertables: `Timescaledb.hypertables`.

### Compression Settings

Compression settings are accessible through the hypertable.

```ruby
Event.hypertable.compression_settings # => [#<Timescaledb::CompressionSettings>, ...]
```

To get compression settings for all hypertables: `Timescaledb.compression_settings`.


### Scopes

The `acts_as_hypertable` macro will be used to generate some extra scopes using the `time_column` argument:

| Scope name             | What they return                      |
|------------------------|---------------------------------------|
| `Model.previous_month` | Records created in the previous month |
| `Model.previous_week`  | Records created in the previous week  |
| `Model.this_month`     | Records created this month            |
| `Model.this_week`      | Records created this week             |
| `Model.yesterday`      | Records created yesterday             |
| `Model.today`          | Records created today                 |
| `Model.last_hour`      | Records created in the last hour      |

All time-related scopes respect your application's timezone.

When you define the `value_column` on your model, it can also be used by the analytical functions in the scopes.

In this example, we are using the [stats_agg](https://docs.timescale.com/api/latest/hyperfunctions/statistical-and-regression-analysis/stats_agg-one-variable/) function to calculate the average and standard deviation of the purchase price.

```ruby
class Event < ActiveRecord::Base
  acts_as_hypertable time_column: "time",
    value_column: "cast(payload->>'price' as float)",
    segment_by: "identifier"

  scope :purchase, -> { where(identifier: "purchase") }

  scope :purchase_stats, -> { purchase.select("stats_agg(#{value_column}) as stats_agg") }
  scope :stats, -> { select("average(stats_agg), stddev(stats_agg)") } # just for descendants aggregated classes
end

Event::PurchaseStatsPerMinute.stats
Event::PurchaseStatsPerHour.stats => [#<Event::PurchaseStatsPerHour:0x00000001204de268 average: 519.8333333333334, stddev: 255.8775557359648>,
```

Load the [all_in_one](examples/all_in_one) example to see more details.

### Insert data

The `insert_all` method seems the most effective way to insert data into the hypertable.

```ruby
def generate_fake_data(total: 100_000, start_time: 1.month.ago)
  total.times.flat_map do
    identifier = %w[sign_up login click scroll logout view purchase]
    start_time = start_time + rand(10).seconds
    id = identifier.sample

    payload =  id == "purchase" ? {
      "price" => rand(100..1000)
    } : {
      "name" => Faker::Name.name,
      "email" => Faker::Internet.email,
    }
    {
      time: start_time,
      identifier: id,
      payload: payload
    }
  end
end
Event.insert_all(generate_fake_data, returning: false)
```

Note that `returning: false` is used to avoid the `returning` option to be used.

### Skip default scopes

You can skip the default scopes by passing `skip_default_scopes: true` to the `acts_as_hypertable` macro.

```ruby
class Event < ActiveRecord::Base
  acts_as_hypertable time_column: "time", skip_default_scopes: true
end
```

You can also use `skip_time_vector` to skip the time vector related scopes.
Or you can use `skip_association_scopes` to skip the association scopes.

## Schema Dumper

If you're using the gem with Rails and you want to dump the schema to a file,
the schema dumper will include:

* hypertables configuration
* compression settings
* continuous aggregates (also integrated with Scenic gem)
* compression and retention policies

The idea is try to mimic the last state of art of the database.
The schema dumper will also ignore the `Timescaledb::SchemaDumper::IGNORE_SCHEMAS`
that is an array of schema names that you want to ignore. By default it ignores
all catalog and metadata generated by the extension, but keep in mind you can
change this behavior.

```ruby
Timescaledb::SchemaDumper::IGNORE_SCHEMAS << "ignore_my_schema_too"
```

Note that the schema dumper only provides output for the ruby version of the schema. If you use sql schema, you will need to create the hypertables manually as described in the [RSpec Hooks](#rspec-hooks) section.

## RSpec Hooks

In case you want to use TimescaleDB on a Rails environment, you may have some
issues as the schema dump used for tests does not consider hypertables metadata.

As a work around, you can dynamically create the hypertables yourself for
testing environments using the following hook which you can
define in `spec/rspec_helper.rb`:


```ruby
config.before(:suite) do

  hypertable_models = ActiveRecord::Base.descendants.select(&:acts_as_hypertable?)

  hypertable_models.each do |klass|
    table_name = klass.table_name
    time_column = klass.hypertable_options[:time_column]

    if klass.try(:hypertable).present?
      ApplicationRecord.logger.info "hypertable already created for '#{table_name}', skipping."
      next
    end

    ApplicationRecord.connection.instance_exec(table_name, time_column) do |table_name, time_column|
      create_hypertable(table_name, time_column: time_column, chunk_time_interval: '1 day')
    end
  end
end
```

## More resources

If you want to learn more about TimescaleDB with Ruby code, you can check the [examples](examples) folder and videos below:

- The [all in one](examples/all_in_one) shows a complete example of how to use the gem.

### Toolkit examples

Check the [examples/toolkit-demo](examples/toolkit-demo) folder for more examples.

1. [volatility](examples/toolkit-demo/compare_volatility.rb) algorithm.
2. [lttb](examples/toolkit-demo/lttb/lttb_sinatra.rb) algorithm.

You can also watch this talk from RubyConf Thailand which covers the toolkit: [Ruby or SQL? where to process your data](https://www.youtube.com/watch?v=MXAtSZ5Szgk).


### Videos

This library was built during live coding sessions. You can also watch all episodes of the kickoff of this gem here:

1. [Wrapping Functions to Ruby Helpers](https://www.youtube.com/watch?v=hGPsUxLFAYk).
2. [Extending ActiveRecord with Timescale Helpers](https://www.youtube.com/watch?v=IEyJIHk1Clk).
3. [Setup Hypertables for Rails testing environment](https://www.youtube.com/watch?v=wM6hVrZe7xA).
4. [Packing the code to this repository](https://www.youtube.com/watch?v=CMdGAl_XlL4).
4. [the code to this repository](https://www.youtube.com/watch?v=CMdGAl_XlL4).
5. [Working with Timescale continuous aggregates](https://youtu.be/co4HnBkHzVw).
6. [Creating the command-line application in Ruby to explore the Timescale API](https://www.youtube.com/watch?v=I3vM_q2m7T0).

Note that the gem also includes a command line application named `tsdb` built in the last episode.

Check the [command line](https://timescale.github.io/timescaledb-ruby/command_line/) options.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/timescale/timescaledb-ruby. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/timescale/timescaledb-ruby/blob/master/CODE_OF_CONDUCT.md).

The [CHANGELOG](./CHANGELOG.md) is maintained by the community and the maintainers of this gem.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Timescale project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/timescale/timescaledb-ruby/blob/master/CODE_OF_CONDUCT.md).
