# frozen_string_literal: true
require "graphql/dataloader/source"

module GraphQL
  class Dataloader
    class LoadError < GraphQL::Error
      # @return [Array<Integer, String>] The runtime GraphQL path where the failed load was requested
      attr_accessor :graphql_path

      attr_writer :message

      def message
        @message || super
      end

      attr_writer :cause

      def cause
        @cause || super
      end
    end

    def self.use(schema)
      instrumenter = Dataloader::Instrumentation.new
      schema.instrument(:multiplex, instrumenter)
      # TODO this won't work if the mutation is hooked up after this
      schema.mutation.fields.each do |name, field|
        field.extension(MutationFieldExtension)
      end
    end

    class MutationFieldExtension < GraphQL::Schema::FieldExtension
      def resolve(object:, arguments:, context:, **_rest)
        Dataloader.current.clear
        begin
          return_value = yield(object, arguments)
          GraphQL::Execution::Lazy.sync(return_value)
        ensure
          Dataloader.current.clear
        end
      end
    end

    class Instrumentation
      def before_multiplex(multiplex)
        dataloader = Dataloader.new(multiplex)
        Dataloader.begin_dataloading(dataloader)
      end

      def after_multiplex(_m)
        Dataloader.end_dataloading
      end
    end

    class << self
      # @return [Dataloader, nil] The dataloader instance caching loaders for the current thread
      def current
        Thread.current[:graphql_dataloader]
      end

      def current=(dataloader)
        Thread.current[:graphql_dataloader] = dataloader
      end

      # Call the given block using the provided dataloader
      # @param dataloader [Dataloader] A new one is created if one isn't given.
      def load(dataloader = Dataloader.new(nil))
        result = begin
          begin_dataloading(dataloader)
          yield
        ensure
          end_dataloading
        end

        GraphQL::Execution::Lazy.sync(result)
      end

      def begin_dataloading(dataloader)
        self.current ||= dataloader
        increment_level
      end

      def end_dataloading
        decrement_level
        if level < 1
          self.current = nil
        end
      end

      private

      def level
        @level || 0
      end

      def increment_level
        @level ||= 0
        @level += 1
      end

      def decrement_level
        @level ||= 0
        @level -= 1
      end
    end

    def initialize(multiplex)
      @multiplex = multiplex

      @sources = Concurrent::Map.new do |h, source_class|
        h[source_class] = Concurrent::Map.new do |h2, source_key|
          # TODO maybe add `cache_key` API like graphql-batch has
          h2[source_key] = source_class.new(*source_key)
        end
      end

      @async_source_queue = []
    end

    # @param source_class [Class]
    # @param source_key [Object] A cache key for instances of `source_class`
    # @return [Dataloader::Source] an instance of `source_class` for `key`, cached for the duration of the multiplex
    def source_for(source_class, source_key)
      @sources[source_class][source_key]
    end

    def current_query
      @multiplex.context[:current_query]
    end

    # Clear the cached loaders of this dataloader (eg, after running a mutation).
    # @return void
    def clear
      @sources.clear
      nil
    end

    # Register this source for background processing.
    # @param source [Dataloader::Source]
    # @return void
    # @api private
    def enqueue_async_source(source)
      if !@async_source_queue.include?(source)
        @async_source_queue << source
      end
    end

    # Call `.wait` on each pending background loader, and clear the queue.
    # @return void
    # @api private
    def process_async_source_queue
      queue = @async_source_queue
      @async_source_queue = []
      queue.each(&:wait)
    end
  end
end