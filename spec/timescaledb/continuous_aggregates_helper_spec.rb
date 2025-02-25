require 'spec_helper'

RSpec.describe Timescaledb::ContinuousAggregatesHelper do
  let(:test_class) do
    HypertableWithContinuousAggregates
  end

  before(:all) do
    ActiveRecord::Base.connection.instance_exec do
      hypertable_options = {
        time_column: 'ts',
        chunk_time_interval: '1 day',
        compress_segmentby: 'identifier, version',
        compress_orderby: 'ts DESC',
      }
      create_table(:hypertable_with_continuous_aggregates, id: false, hypertable: hypertable_options) do |t|
        t.datetime :ts, null: false
        t.text :identifier, :version, null: false
        t.jsonb :payload
      end
    end
  end

  after(:all) do
    ActiveRecord::Base.connection.drop_table :hypertable_with_continuous_aggregates, if_exists: true, force: :cascade
    Object.send(:remove_const, :HypertableWithContinuousAggregates) if Object.const_defined?(:HypertableWithContinuousAggregates)
  end

  describe '.continuous_aggregates' do
    it 'defines aggregate classes' do
      expect(test_class.const_defined?(:TotalPerMinute)).to be true
      expect(test_class.const_defined?(:TotalPerHour)).to be true
      expect(test_class.const_defined?(:TotalPerDay)).to be true
      expect(test_class.const_defined?(:TotalPerMonth)).to be true

      expect(test_class.const_defined?(:ByVersionPerMinute)).to be true
      expect(test_class.const_defined?(:ByVersionPerHour)).to be true
      expect(test_class.const_defined?(:ByVersionPerDay)).to be true
      expect(test_class.const_defined?(:ByVersionPerMonth)).to be true

      expect(test_class.const_defined?(:ByIdentifierPerMinute)).to be true
      expect(test_class.const_defined?(:ByIdentifierPerHour)).to be true
      expect(test_class.const_defined?(:ByIdentifierPerDay)).to be true
      expect(test_class.const_defined?(:ByIdentifierPerMonth)).to be true
    end

    it 'sets up correct table names for aggregates' do
      expect(test_class::TotalPerMinute.table_name).to eq('total_per_minute')
      expect(test_class::TotalPerHour.table_name).to eq('total_per_hour')
      expect(test_class::TotalPerDay.table_name).to eq('total_per_day')
      expect(test_class::TotalPerMonth.table_name).to eq('total_per_month')

      expect(test_class::ByVersionPerMinute.table_name).to eq('by_version_per_minute')
      expect(test_class::ByVersionPerHour.table_name).to eq('by_version_per_hour')
      expect(test_class::ByVersionPerDay.table_name).to eq('by_version_per_day')
      expect(test_class::ByVersionPerMonth.table_name).to eq('by_version_per_month')

      expect(test_class::ByIdentifierPerMinute.table_name).to eq('by_identifier_per_minute')
      expect(test_class::ByIdentifierPerHour.table_name).to eq('by_identifier_per_hour')
      expect(test_class::ByIdentifierPerDay.table_name).to eq('by_identifier_per_day')
      expect(test_class::ByIdentifierPerMonth.table_name).to eq('by_identifier_per_month')
    end

    it 'setups up configuration for each aggregate' do
      expected_config = {
        scope_name: :total,
        select: "count(*) as total",
        where: nil,
        group_by: [],
        refresh_policy: {
          minute: { start_offset: "10 minutes", end_offset: "1 minute", schedule_interval: "1 minute" },
          hour:   { start_offset: "4 hour",     end_offset: "1 hour",   schedule_interval: "1 hour" },
          day:    { start_offset: "3 day",      end_offset: "1 day",    schedule_interval: "1 hour" },
          month:  { start_offset: "3 month",    end_offset: "1 hour",   schedule_interval: "1 hour" }
        }
      }
      base_query = test_class::TotalPerMinute.base_query
      expect(base_query).to eq("SELECT time_bucket('1 minute', ts) as ts, count(*) as total FROM \"hypertable_with_continuous_aggregates\" GROUP BY time_bucket('1 minute', ts)")
      expect(test_class::TotalPerMinute.config).to eq(expected_config)
    end

    it "sets the where clause for each aggregate" do
      base_query = test_class::PurchaseStatsPerMinute.base_query
      expect(base_query).to include("WHERE (identifier = 'purchase')")
    end


    it 'defines rollup scope for aggregates' do
      test_class.create_continuous_aggregates
      aggregate_classes = [test_class::TotalPerMinute, test_class::TotalPerHour, test_class::TotalPerDay, test_class::TotalPerMonth]

      expect(test_class::TotalPerMinute.base_query).to eq("SELECT time_bucket('1 minute', ts) as ts, count(*) as total FROM \"hypertable_with_continuous_aggregates\" GROUP BY time_bucket('1 minute', ts)")
      expect(test_class::TotalPerMonth.base_query).to eq("SELECT time_bucket('1 month', ts) as ts, sum(total) as total FROM \"total_per_day\" GROUP BY time_bucket('1 month', ts)")
      expect(test_class::TotalPerDay.base_query).to eq("SELECT time_bucket('1 day', ts) as ts, sum(total) as total FROM \"total_per_hour\" GROUP BY time_bucket('1 day', ts)")
      expect(test_class::TotalPerHour.base_query).to eq("SELECT time_bucket('1 hour', ts) as ts, sum(total) as total FROM \"total_per_minute\" GROUP BY time_bucket('1 hour', ts)")

      expect(test_class::ByVersionPerMinute.base_query).to eq("SELECT time_bucket('1 minute', ts) as ts, identifier, version, count(*) as total FROM \"hypertable_with_continuous_aggregates\" GROUP BY time_bucket('1 minute', ts), identifier, version")
      expect(test_class::ByVersionPerMonth.base_query).to eq("SELECT time_bucket('1 month', ts) as ts, identifier, version, sum(total) as total FROM \"by_version_per_day\" GROUP BY time_bucket('1 month', ts), identifier, version")
      expect(test_class::ByVersionPerDay.base_query).to eq("SELECT time_bucket('1 day', ts) as ts, identifier, version, sum(total) as total FROM \"by_version_per_hour\" GROUP BY time_bucket('1 day', ts), identifier, version")
      expect(test_class::ByVersionPerHour.base_query).to eq("SELECT time_bucket('1 hour', ts) as ts, identifier, version, sum(total) as total FROM \"by_version_per_minute\" GROUP BY time_bucket('1 hour', ts), identifier, version")

      expect(test_class::ByIdentifierPerMinute.base_query).to eq("SELECT time_bucket('1 minute', ts) as ts, identifier, count(*) as total FROM \"hypertable_with_continuous_aggregates\" GROUP BY time_bucket('1 minute', ts), identifier")
      expect(test_class::ByIdentifierPerMonth.base_query).to eq("SELECT time_bucket('1 month', ts) as ts, identifier, sum(total) as total FROM \"by_identifier_per_day\" GROUP BY time_bucket('1 month', ts), identifier")
      expect(test_class::ByIdentifierPerDay.base_query).to eq("SELECT time_bucket('1 day', ts) as ts, identifier, sum(total) as total FROM \"by_identifier_per_hour\" GROUP BY time_bucket('1 day', ts), identifier")
      expect(test_class::ByIdentifierPerHour.base_query).to eq("SELECT time_bucket('1 hour', ts) as ts, identifier, sum(total) as total FROM \"by_identifier_per_minute\" GROUP BY time_bucket('1 hour', ts), identifier") 

      expect(test_class::PurchaseStatsPerMinute.base_query).to eq("SELECT time_bucket('1 minute', ts) as ts, stats_agg(cast(payload->>'price' as float)) as stats_agg FROM \"hypertable_with_continuous_aggregates\" WHERE (identifier = 'purchase') GROUP BY time_bucket('1 minute', ts)")
      expect(test_class::PurchaseStatsPerHour.base_query).to eq("SELECT time_bucket('1 hour', ts) as ts, rollup(stats_agg) as stats_agg FROM \"purchase_stats_per_minute\" GROUP BY time_bucket('1 hour', ts)")
      expect(test_class::PurchaseStatsPerDay.base_query).to eq("SELECT time_bucket('1 day', ts) as ts, rollup(stats_agg) as stats_agg FROM \"purchase_stats_per_hour\" GROUP BY time_bucket('1 day', ts)")
      expect(test_class::PurchaseStatsPerMonth.base_query).to eq("SELECT time_bucket('1 month', ts) as ts, rollup(stats_agg) as stats_agg FROM \"purchase_stats_per_day\" GROUP BY time_bucket('1 month', ts)")
    end
  end

  describe '.create_continuous_aggregates' do
    before do
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
    end

    it 'creates materialized views for each aggregate' do
      test_class.create_continuous_aggregates

      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS total_per_minute/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS total_per_hour/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS total_per_day/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS total_per_month/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS by_version_per_day/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS by_version_per_hour/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS by_version_per_minute/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS by_identifier_per_month/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS purchase_stats_per_minute/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS purchase_stats_per_hour/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS purchase_stats_per_day/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/CREATE MATERIALIZED VIEW IF NOT EXISTS purchase_stats_per_month/i)
    end

    it 'sets up refresh policies for each aggregate' do
      test_class.create_continuous_aggregates

      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*total_per_minute/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*total_per_hour/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*total_per_day/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*by_version_per_hour/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*by_identifier_per_day/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*by_identifier_per_month/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*by_version_per_day/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*by_version_per_month/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*purchase_stats_per_minute/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*purchase_stats_per_hour/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*purchase_stats_per_day/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/add_continuous_aggregate_policy.*purchase_stats_per_month/i)
    end
  end

  describe 'refresh policies' do
    it 'defines appropriate refresh policies for each timeframe' do
      policies = {
        minute: { start_offset: "10 minutes", end_offset: "1 minute", schedule_interval: "1 minute" },
        hour:   { start_offset: "4 hour",     end_offset: "1 hour",   schedule_interval: "1 hour" },
        day:    { start_offset: "3 day",      end_offset: "1 day",    schedule_interval: "1 hour" },
        month:  { start_offset: "3 month",    end_offset: "1 hour",   schedule_interval: "1 hour" } 
      }

      policies.each do |timeframe, expected_policy|
        %w[Total ByVersion ByIdentifier PurchaseStats].each do |klass|
          actual_policy = test_class.const_get("#{klass}Per#{timeframe.to_s.capitalize}").refresh_policy
          expect(actual_policy).to eq(expected_policy)
        end
      end
    end
  end

  describe '.drop_continuous_aggregates' do
    before do
      allow(ActiveRecord::Base.connection).to receive(:execute).and_call_original
    end
    it 'drops all continuous aggregates' do
      test_class.drop_continuous_aggregates
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS total_per_month CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS total_per_day CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS total_per_hour CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS total_per_minute CASCADE/i)

      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_version_per_month CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_version_per_day CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_version_per_hour CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_version_per_minute CASCADE/i)

      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_identifier_per_month CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_identifier_per_day CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_identifier_per_hour CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS by_identifier_per_minute CASCADE/i)

      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS purchase_stats_per_month CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS purchase_stats_per_day CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS purchase_stats_per_hour CASCADE/i)
      expect(ActiveRecord::Base.connection).to have_received(:execute).with(/DROP MATERIALIZED VIEW IF EXISTS purchase_stats_per_minute CASCADE/i)
    end
  end
end