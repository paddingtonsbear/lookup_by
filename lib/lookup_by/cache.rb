module LookupBy
  class Cache
    attr_reader :klass, :primary_key
    attr_reader :cache, :stats
    attr_reader :field, :order, :type, :limit, :find, :write

    def initialize(klass, options = {})
      @klass       = klass
      @primary_key = klass.primary_key
      @field       = options[:field].to_sym
      @cache       = {}
      @order       = options[:order] || field
      @read        = options[:find]
      @write       = options[:find_or_create]

      @stats       = { db: Hash.new(0), cache: Hash.new(0) }

      raise ArgumentError, %Q(unknown attribute "#{field}" for <#{klass}>) unless klass.column_names.include?(field.to_s)

      case options[:cache]
      when true
        @type   = :all
        @read   = false if @read.nil?
      when ::Fixnum
        raise ArgumentError, "`#{@klass}.lookup_by :#{@field}` options[:find] must be true when caching N" if @read == false

        @type   = :lru
        @limit  = options[:cache]
        @cache  = Rails.configuration.allow_concurrency ? Caching::SafeLRU.new(@limit) : Caching::LRU.new(@limit)
        @read   = true
        @write  = false if @write.nil?
      else
        @read   = true
      end
    end

    def reload
      return unless cache_all?

      cache.clear

      ::ActiveRecord::Base.connection.send :log, "", "#{klass.name} Load Cache All" do
        klass.order(order).each do |i|
          cache[i.id] = i
        end
      end
    end

    def create!(*args, &block)
      created = klass.create!(*args, &block)
      cache[created.id] = created if cache?
      created
    end

    def fetch(value)
      increment :cache, :get

      found = cache_read(value) if cache?
      found ||= db_read(value)  if read_through?

      cache[found.id] = found if found && cache?

      found
    end

    def read_through?
      @read
    end

  private

    def cache_read(value)
      if value.is_a? Fixnum
        found = cache[value]
      else
        found = cache.values.detect { |o| o.send(field) == value }
      end

      increment :cache, found ? :hit : :miss

      found
    end

    # TODO: Handle race condition on create! failure
    def db_read(value)
      increment :db, :get

      column = value.is_a?(Fixnum) ? primary_key : field

      found   = klass.where(column => value).first
      found ||= klass.create!(column => value) if !found && write? && column != primary_key

      increment :db, found ? :hit : :miss
      found
    end

    def cache?
      !!type
    end

    def cache_all?
      type == :all
    end


    def write?
      !!write
    end

    def increment(type, stat)
      @stats[type][stat] += 1
    end
  end
end