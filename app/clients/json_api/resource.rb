# A resource of a JSON:API document, whose relationships resolve through the store it was fetched into.
module JsonApi
  class Resource
    attr_reader :type, :id, :attributes

    def initialize(store, data)
      @store = store
      @type = data.fetch("type")
      @id = data.fetch("id")
      @attributes = data.fetch("attributes", {})
      @relationships = data.fetch("relationships", {})
    end

    # nil for an attribute the document left out.
    def [](name)
      attributes[name]
    end

    # The related resource, nil for an empty to-one relationship, or the resources of a to-many one.
    def related(name)
      identifiers = linkage(name)
      return identifiers.map { |identifier| @store.find(identifier) } if identifiers.is_a?(Array)

      identifiers && @store.find(identifiers)
    end

    # The type and id of the related resources, which may not have been fetched yet.
    def linkage(name)
      @relationships.fetch(name).fetch("data")
    end
  end
end
