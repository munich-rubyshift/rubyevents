require "test_helper"

class JsonApi::ClientTest < ActiveSupport::TestCase
  BASE = "https://api.example.org/v1"

  setup do
    @client = JsonApi::Client.new(BASE)
  end

  test "fetches every page of a list by following links.next, relative or not" do
    stub_document("/people.json", data: [person("1")], links: {next: "people.json?page=2"})
    stub_document("/people.json?page=2", data: [person("2")], links: {next: {href: "/v1/people.json?page=3"}})
    stub_document("/people.json?page=3", data: [person("3")], links: {next: "#{BASE}/people.json?page=4"})
    stub_document("/people.json?page=4", data: [], links: {next: nil})

    assert_equal %w[1 2 3], @client.fetch("/people.json").map(&:id)
  end

  test "resolves relationships to included resources and to resources of earlier documents" do
    stub_document("/people.json", data: [person("anna")])
    stub_document("/talks/1.json",
      data: talk(speakers: {data: [{type: "people", id: "anna"}]}, event: {data: {type: "events", id: "e1"}}, venue: {data: nil}),
      included: [{type: "events", id: "e1", attributes: {title: "Meetup"}}])

    @client.fetch("/people.json")
    talk = @client.fetch("/talks/1.json")

    assert_equal "A talk", talk["title"]
    assert_equal ["Anna anna"], talk.related("speakers").map { |speaker| speaker["name"] }
    assert_equal "Meetup", talk.related("event")["title"]
    assert_nil talk.related("venue")
    assert_equal [{"type" => "people", "id" => "anna"}], talk.linkage("speakers")
  end

  test "can't resolve a relationship to a resource it hasn't fetched" do
    stub_document("/talks/1.json", data: talk(speakers: {data: [{type: "people", id: "anna"}]}))

    talk = @client.fetch("/talks/1.json")

    assert_raises(JsonApi::Store::MissingResource) { talk.related("speakers") }
  end

  test "doesn't follow links.next out of the API" do
    stub_document("/people.json", data: [], links: {next: "https://elsewhere.example.org/v1/people.json?page=2"})

    error = assert_raises(ApplicationClient::Error) { @client.fetch("/people.json") }
    assert_match "is not part of #{BASE}", error.message
  end

  test "stops when links.next leads back to a page it fetched" do
    stub_document("/people.json", data: [], links: {next: "people.json"})

    error = assert_raises(ApplicationClient::Error) { @client.fetch("/people.json") }
    assert_match "came up twice", error.message
  end

  test "raises when the API answers with an error" do
    stub_request(:get, "#{BASE}/events/missing.json").to_return(status: 404, body: {errors: [{status: "404"}]}.to_json)

    assert_raises(ApplicationClient::NotFound) { @client.fetch("/events/missing.json") }
  end

  private

  def stub_document(path, **document)
    stub_request(:get, "#{BASE}#{path}").to_return(body: {jsonapi: {version: "1.1"}, **document}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def person(id)
    {type: "people", id: id, attributes: {name: "Anna #{id}"}}
  end

  def talk(**relationships)
    {type: "talks", id: "1", attributes: {title: "A talk"}, relationships: relationships}
  end
end
