# A client for JSON:API documents (https://jsonapi.org). It keeps every resource it fetches in its store,
# so that a relationship resolves across documents, like a talk's speakers listed in another document.
module JsonApi
  class Client < ApplicationClient
    attr_reader :base_uri, :store

    def initialize(base_uri, store: Store.new)
      super()
      @base_uri = base_uri.chomp("/")
      @store = store
    end

    # The primary data of the document at path: a resource, nil, or the resources of every page of a list.
    def fetch(path)
      documents = pages("#{base_uri}#{path}")
      documents.each { |document| Array(document["included"]).each { |data| store.add(data) } }

      data = documents.map { |document| document.fetch("data") }
      return data.first && store.add(data.first) unless data.first.is_a?(Array)

      data.flatten(1).map { |resource| store.add(resource) }
    end

    private

    # The document at url, and the pages that follow it through `links.next`.
    def pages(url)
      documents = []
      fetched = Set.new

      while url
        raise Error, "#{url} is not part of #{base_uri}" unless url.start_with?("#{base_uri}/")
        raise Error, "#{url} came up twice while following links.next" unless fetched.add?(url)

        documents << JSON.parse(get(url.delete_prefix(base_uri)).body)
        url = next_url(url, documents.last)
      end

      documents
    end

    # A link is a URL, which may be relative, or a link object with the URL in its `href`.
    def next_url(url, document)
      link = document.dig("links", "next")
      link = link["href"] if link.is_a?(Hash)

      link && URI.join(url, link).to_s
    end
  end
end
