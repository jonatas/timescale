require 'active_record/connection_adapters/postgresql_adapter'

# Useful methods to run TimescaleDB in you Ruby app.
module Timescaledb
  # Migration helpers can help you to setup hypertables by default.
  module MigrationHelpers
    # `create_table` accepts a `hypertable` argument with options for creating
    # a TimescaleDB hypertable.
    #
    # See https://docs.timescale.com/api/latest/hypertable/create_hypertable/#optional-arguments
    # for additional options supported by the plugin.
    #
    # @example
    #  options = {
    #    time_column: 'created_at',
    #    chunk_time_interval: '1 min',
    #    compress_segmentby: 'identifier',
    #    compress_orderby: 'created_at',
    #    compress_after: '7 days'
    #  }
    #
    #  create_table(:events, id: false, hypertable: options) do |t|
    #    t.string :identifier, null: false
    #    t.jsonb :payload
    #    t.timestamps
    #  end
    def create_table(table_name, id: :primary_key, primary_key: nil, force: nil, **options)
      super
      create_hypertable(table_name, **options[:hypertable]) if options.key?(:hypertable)
    end

    # Override the valid_table_definition_options to include hypertable.
    def valid_table_definition_options # :nodoc:
      super + [:hypertable]
    end

    # Setup hypertable from options
    # @see create_table with the hypertable options.
    def create_hypertable(table_name,
                          time_column: 'created_at',
                          chunk_time_interval: '1 week',
                          compress_segmentby: nil,
                          compress_orderby: 'created_at',
                          compress_after: nil,
                          drop_after: nil,
                          partition_column: nil,
                          number_partitions: nil,
                          **hypertable_options)

      original_logger = ActiveRecord::Base.logger
      ActiveRecord::Base.logger = Logger.new(STDOUT)

      dimension = "by_range(#{quote(time_column)}, #{parse_interval(chunk_time_interval)})"

      arguments = [ quote(table_name), dimension,
        *hypertable_options.map { |k, v| "#{k} => #{quote(v)}" }
      ]

      execute "SELECT create_hypertable(#{arguments.compact.join(', ')})"

      if partition_column && number_partitions
        execute "SELECT add_dimension('#{table_name}', by_hash(#{quote(partition_column)}, #{number_partitions}))"
      end

      if compress_segmentby || compress_after
        add_compression_policy(table_name, orderby: compress_orderby, segmentby: compress_segmentby, compress_after: compress_after)
      end

      if drop_after
        add_retention_policy(table_name, drop_after: drop_after)
      end
    ensure
      ActiveRecord::Base.logger = original_logger if original_logger
    end

    # Create a new continuous aggregate
    #
    # @param name [String, Symbol] The name of the continuous aggregate.
    # @param query [String] The SQL query for the aggregate view definition.
    # @param with_data [Boolean] Set to true to create the aggregate WITH DATA
    # @param refresh_policies [Hash] Set to create a refresh policy
    # @option refresh_policies [String] start_offset: INTERVAL or integer
    # @option refresh_policies [String] end_offset: INTERVAL or integer
    # @option refresh_policies [String] schedule_interval: INTERVAL
    # @option materialized_only [Boolean] Override the WITH clause 'timescaledb.materialized_only'
    # @option create_group_indexes [Boolean] Override the WITH clause 'timescaledb.create_group_indexes'
    # @option finalized [Boolean] Override the WITH clause 'timescaledb.finalized'
    #
    # @see https://docs.timescale.com/api/latest/continuous-aggregates/create_materialized_view/
    # @see https://docs.timescale.com/api/latest/continuous-aggregates/add_continuous_aggregate_policy/
    #
    # @example
    #   create_continuous_aggregate(:activity_counts, query: <<-SQL, refresh_policies: { schedule_interval: "INTERVAL '1 hour'" })
    #     SELECT
    #       time_bucket(INTERVAL '1 day', activity.created_at) AS bucket,
    #       count(*)
    #     FROM activity
    #     GROUP BY bucket
    #   SQL
    #
    def create_continuous_aggregate(table_name, query, **options)
      execute <<~SQL
        CREATE MATERIALIZED VIEW #{table_name}
        WITH (
          timescaledb.continuous
          #{build_with_clause_option_string(:materialized_only, options)}
          #{build_with_clause_option_string(:create_group_indexes, options)}
          #{build_with_clause_option_string(:finalized, options)}
        ) AS
        #{query.respond_to?(:to_sql) ? query.to_sql : query}
        WITH #{'NO' unless options[:with_data]} DATA;
      SQL

      create_continuous_aggregate_policy(table_name, **(options[:refresh_policies] || {}))
    end

    alias_method :create_continuous_aggregates, :create_continuous_aggregate

    #  Drop a new continuous aggregate.
    #
    #  It basically DROP MATERIALIZED VIEW for a given @name.
    #
    # @param name [String, Symbol] The name of the continuous aggregate view.
    def drop_continuous_aggregate view_name
      execute "DROP MATERIALIZED VIEW #{view_name}"
    end

    alias_method :drop_continuous_aggregates, :drop_continuous_aggregate

    def create_continuous_aggregate_policy(table_name, **options)
      return if options.empty?

      # TODO: assert valid keys
      execute <<~SQL
        SELECT add_continuous_aggregate_policy('#{table_name}',
          start_offset => #{options[:start_offset]},
          end_offset => #{options[:end_offset]},
          schedule_interval => #{options[:schedule_interval]});
      SQL
    end

    def remove_continuous_aggregate_policy(table_name)
      execute "SELECT remove_continuous_aggregate_policy('#{table_name}')"
    end

    def create_retention_policy(table_name, drop_after:)
      execute "SELECT add_retention_policy('#{table_name}', drop_after => #{parse_interval(drop_after)})"
    end

    alias_method :add_retention_policy, :create_retention_policy

    def remove_retention_policy(table_name)
      execute "SELECT remove_retention_policy('#{table_name}')"
    end


    # Enable compression policy.
    #
    # @param table_name [String] The name of the table.
    # @param orderby [String] The column to order by.
    # @param segmentby [String] The column to segment by.
    # @param compress_after [String] The interval to compress after.
    # @param compression_chunk_time_interval [String] In case to merge chunks.
    #
    # @see https://docs.timescale.com/api/latest/compression/add_compression_policy/
    def add_compression_policy(table_name, orderby:, segmentby:, compress_after: nil, compression_chunk_time_interval: nil)
      options = []
      options << 'timescaledb.compress'
      options << "timescaledb.compress_orderby = '#{orderby}'" if orderby
      options << "timescaledb.compress_segmentby = '#{segmentby}'" if segmentby
      options << "timescaledb.compression_chunk_time_interval = INTERVAL '#{compression_chunk_time_interval}'" if compression_chunk_time_interval
      execute <<~SQL
        ALTER TABLE #{table_name} SET (
          #{options.join(',')}
        )
      SQL
      execute "SELECT add_compression_policy('#{table_name}', compress_after => INTERVAL '#{compress_after}')" if compress_after
    end

    private

    # Build a string for the WITH clause of the CREATE MATERIALIZED VIEW statement.
    # When the option is omitted, this method returns an empty string, which allows this gem to use the
    # defaults provided by TimescaleDB.
    def build_with_clause_option_string(option_key, options)
      return '' unless options.key?(option_key)

      value = options[option_key] ? 'true' : 'false'
      ",timescaledb.#{option_key}=#{value}"
    end

    def parse_interval(interval)
      if interval.is_a?(Numeric)
        interval
      else
        "INTERVAL '#{interval}'"
      end
    end
  end
end

ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.include(Timescaledb::MigrationHelpers)
