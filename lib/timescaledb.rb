require 'active_record'

require_relative 'timescaledb/application_record'
require_relative 'timescaledb/acts_as_hypertable'
require_relative 'timescaledb/acts_as_hypertable/core'
require_relative 'timescaledb/continuous_aggregates_helper'
require_relative 'timescaledb/connection'
require_relative 'timescaledb/toolkit'
require_relative 'timescaledb/chunk'
require_relative 'timescaledb/compression_settings'
require_relative 'timescaledb/connection_handling'
require_relative 'timescaledb/continuous_aggregates'
require_relative 'timescaledb/dimensions'
require_relative 'timescaledb/hypertable'
require_relative 'timescaledb/job'
require_relative 'timescaledb/job_stats'
require_relative 'timescaledb/schema_dumper'
require_relative 'timescaledb/stats'
require_relative 'timescaledb/stats_report'
require_relative 'timescaledb/migration_helpers'
require_relative 'timescaledb/command_recorder'
require_relative 'timescaledb/extension'
require_relative 'timescaledb/version'

module Timescaledb
  module_function

  def connection
    Connection.instance
  end

  def extension
    Extension
  end

  def chunks
    Chunk.all
  end

  def hypertables
    Hypertable.all
  end

  def continuous_aggregates
    ContinuousAggregates.all
  end

  def compression_settings
    CompressionSettings.all
  end

  def jobs
    Job.all
  end

  def job_stats
    JobStats.all
  end

  def stats(scope=Hypertable.all)
    StatsReport.resume(scope)
  end

  def default_hypertable_options
    Timescaledb::ActsAsHypertable::DEFAULT_OPTIONS
  end
end

begin
  require 'scenic'
  require_relative 'timescaledb/scenic/adapter'
  require_relative 'timescaledb/scenic/extension'

  Scenic.configure do |config|
    config.database = Timescaledb::Scenic::Adapter.new
  end

rescue LoadError
  # This is expected when the scenic gem is not being used
end
