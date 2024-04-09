RSpec.describe Timescaledb::MigrationHelpers, database_cleaner_strategy: :truncation do
  describe ".create_table" do
    let(:con) { ActiveRecord::Base.connection }

    before(:each) do
      if con.table_exists?(:migration_tests)
        con.drop_table :migration_tests, force: :cascade
      end
    end

    subject(:create_table) do
      con.create_table :migration_tests, hypertable: hypertable_options, id: false do |t|
        t.string :identifier
        t.jsonb :payload
        t.timestamps
      end
    end

    let(:hypertable_options) do
      {
        time_column: 'created_at',
        chunk_time_interval: '1 min',
        compress_segmentby: 'identifier',
        compress_orderby: 'created_at',
        compression_interval: '7 days'
      }
    end

    it 'call create_hypertable with params' do
      expect(ActiveRecord::Base.connection)
        .to receive(:create_hypertable)
        .with(:migration_tests, hypertable_options)
        .once

      create_table
    end

    context 'with hypertable options' do
      let(:hypertable) do
        Timescaledb::Hypertable.find_by(hypertable_name: :migration_tests)
      end

      it 'enables compression' do
        create_table

        expect(hypertable.attributes).to include({
          "compression_enabled"=>true,
          "hypertable_name"=>"migration_tests",
          "hypertable_schema" => "public",
          "num_chunks" => 0,
          "num_dimensions" => 1,
          "tablespaces" => nil})
      end
    end
  end

  describe ".create_continuous_aggregates" do
    let(:con) { ActiveRecord::Base.connection }

    before(:each) do
      if con.table_exists?(:ticks)
        con.drop_table :ticks, force: :cascade
      end
      con.create_table :ticks, hypertable: hypertable_options, id: false do |t|
        t.string :symbol
        t.decimal :price
        t.integer :volume
        t.timestamps
      end
    end

    after(:each) do
      con.drop_continuous_aggregates(:ohlc_1m)
    end

    let(:hypertable_options) do
      {
        time_column: 'created_at',
        chunk_time_interval: '1 min',
        compress_segmentby: 'symbol',
        compress_orderby: 'created_at',
        compression_interval: '7 days'
      }
    end

    let(:model) do
      Tick = Class.new(ActiveRecord::Base) do
        self.table_name = 'ticks'
        self.primary_key = 'symbol'

        acts_as_hypertable
      end
    end

    let(:query) do
      model.select("time_bucket('1m', created_at) as time,
          symbol,
          FIRST(price, created_at) as open,
          MAX(price) as high,
          MIN(price) as low,
          LAST(price, created_at) as close,
          SUM(volume) as volume").group("1,2")
    end
    let(:options) do
      {with_data: true}
    end

    subject(:create_caggs) { con.create_continuous_aggregates('ohlc_1m', query, **options) }

    specify do
      expect do
        create_caggs
      end.to change { model.continuous_aggregates.count }.from(0).to(1)

      expect(model.continuous_aggregates.first.jobs).to be_empty
    end

    context 'when using refresh policies' do
      let(:options) do
        {
          with_data: false,
          refresh_policies: {
            start_offset: "INTERVAL '1 month'",
            end_offset: "INTERVAL '1 minute'",
            schedule_interval: "INTERVAL '1 minute'"
          }
        }
      end

      specify do
        expect do
          create_caggs
        end.to change { model.continuous_aggregates.count }.from(0).to(1)

        expect(model.continuous_aggregates.first.jobs).not_to be_empty
      end
    end

    context 'when overriding WITH clauses' do
      let(:options) do
        {
          materialized_only: true,
          create_group_indexes: true,
          finalized: true
        }
      end

      before do
        allow(ActiveRecord::Base.connection).to(receive(:execute).and_call_original)
      end

      specify do
        expect do
          create_caggs
        end.to change { model.continuous_aggregates.count }.from(0).to(1)
      end

      context 'when overriding WITH clause timescaledb.materialized_only' do
        let(:options) do
          {
            materialized_only: true
          }
        end

        specify do
          create_caggs
          expect(ActiveRecord::Base.connection).to have_received(:execute).with(include('timescaledb.materialized_only=true'))
        end
      end

      context 'when overriding WITH clause timescaledb.create_group_indexes' do
        let(:options) do
          {
            create_group_indexes: true
          }
        end

        specify do
          create_caggs
          expect(ActiveRecord::Base.connection).to have_received(:execute).with(include('timescaledb.create_group_indexes=true'))
        end
      end

      context 'when overriding WITH clause timescaledb.finalized' do
        let(:options) do
          {
            finalized: true
          }
        end

        specify do
          create_caggs
          expect(ActiveRecord::Base.connection).to have_received(:execute).with(include('timescaledb.finalized=true'))
        end
      end
    end
  end
end
