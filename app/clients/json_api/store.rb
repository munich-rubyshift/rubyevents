# The resources a JsonApi::Client has fetched, by type and id.
module JsonApi
  class Store
    class MissingResource < KeyError; end

    def initialize
      @resources = {}
    end

    def add(data)
      resource = Resource.new(self, data)
      @resources[[resource.type, resource.id]] = resource
    end

    def find(identifier)
      type, id = identifier.values_at("type", "id")
      @resources.fetch([type, id]) { raise MissingResource, "#{type} #{id} hasn't been fetched" }
    end

    def all(type)
      @resources.values.select { |resource| resource.type == type }
    end
  end
end
