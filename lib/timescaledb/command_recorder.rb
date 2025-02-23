# Useful methods to run TimescaleDB in you Ruby app.
module Timescaledb
  # Migration helpers can help you to setup hypertables by default.
  module CommandRecorder
    def create_continuous_aggregate(*args)
      record(:create_continuous_aggregate, args)
    end
    alias_method :create_continuous_aggregates, :create_continuous_aggregate

    def invert_create_continuous_aggregate(args)
      [:drop_continuous_aggregate, args.first]
    end
  end
end
ActiveRecord::Migration::CommandRecorder.include Timescaledb::CommandRecorder
