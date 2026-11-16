require "test_helper"

class MunichRubyshiftImportTest < ActiveSupport::TestCase
  API = MunichRubyshiftImport::API

  setup do
    @root = Pathname.new(Dir.mktmpdir)

    write "data/speakers.yml", <<~YAML
      ---
      - name: "Bea Builder"
        github: "bea"
        website: "https://bea.example.org"
        slug: "bea-builder"
        aliases:
          - name: "Bea B."
            slug: "bea-b"
      - name: "Kuba Kuzma"
        github: ""
        slug: "kuba-kuzma"
      - name: "Sam Same"
        github: "sam-one"
        slug: "sam-same"
      - name: 'Untouched Person'
        github: ""
        slug: "untouched-person"
    YAML

    write "data/munich-rubyshift/series.yml", <<~YAML
      ---
      id: "munich-rubyshift"
      old_event_ids:
        - "munich-rubyshift-meetup"
      name: "Munich Rubyshift"
      location: "Munich, Germany"
      twitter: "old_handle"
      coordinates:
        latitude: 48.13
        longitude: 11.58
    YAML

    write "data/munich-rubyshift/munich-rubyshift-2025-01-16/event.yml", "---\nid: \"munich-rubyshift-2025-01-16\"\n"

    write "data/munich-rubyshift/meetup-2025-07-17/event.yml", <<~YAML
      ---
      id: "meetup-2025-07-17"
      old_talk_ids:
        - "munich-rubyshift-july-2025"
      title: "Old title"
      status: "postponed"
    YAML

    write "data/munich-rubyshift/meetup-2025-07-17/videos.yml", <<~YAML
      ---
      - id: "hotwire-native"
        old_id: "aron-wolf-munich-rubyshift-2025-07-17"
        title: "Old title"
        video_provider: "youtube"
        video_id: "abc123"
      - id: "dropped-talk"
        title: "Dropped"
    YAML

    write "data/munich-rubyshift/meetup-2025-07-17/schedule.yml", "---\ndays: []\n"

    stub_api
    @report = MunichRubyshiftImport.new(root: @root, today: Date.new(2025, 7, 20)).run
  end

  teardown do
    FileUtils.rm_rf(@root)
  end

  test "writes the series with RubyEvents' keys, and only what the API delivers" do
    assert_equal({
      "id" => "munich-rubyshift",
      "name" => "Munich Rubyshift",
      "kind" => "meetup",
      "language" => "English",
      "timezone" => "Europe/Berlin",
      "meetup" => "https://www.meetup.com/munich-rubyshift/",
      "ended" => false
    }, read("data/munich-rubyshift/series.yml"))
  end

  test "replaces the series folder with the events the API lists" do
    assert_not @root.join("data/munich-rubyshift/munich-rubyshift-2025-01-16").exist?
    assert_not @root.join("data/munich-rubyshift/meetup-2025-07-17/schedule.yml").exist?
    assert_includes @report, "removed munich-rubyshift/munich-rubyshift-2025-01-16"
    assert_includes @report, "added munich-rubyshift/meetup-2025-07-24"
    assert_not_includes @report, "added munich-rubyshift/meetup-2025-07-17"
  end

  test "writes an event with values from its series and venue, leaving the series' links to the series" do
    assert_equal({
      "id" => "meetup-2025-07-17",
      "title" => "Munich Rubyshift Meetup July 17, 2025",
      "subtitle" => "Ruby Meetup July 2025",
      "kind" => "meetup",
      "start_date" => "2025-07-17",
      "start_time" => "19:00",
      "description" => "Line one\n\nLine two",
      "twitter" => "muc_rubyshift",
      "location" => "Munich, Germany",
      "timezone" => "Europe/Berlin",
      "hybrid" => true,
      "coordinates" => {"latitude" => 48.1, "longitude" => 11.5}
    }, read("data/munich-rubyshift/meetup-2025-07-17/event.yml"))
  end

  test "writes an event without a venue without a location" do
    event = read("data/munich-rubyshift/meetup-2025-07-24/event.yml")

    assert_equal "cancelled", event["status"]
    assert_equal "Munich Rubyshift Meetup July 24, 2025", event["title"]
    assert_not event.key?("subtitle")
    assert_not event.key?("location")
    assert_not event.key?("coordinates")
    assert_not @root.join("data/munich-rubyshift/meetup-2025-07-24/venue.yml").exist?
  end

  test "writes the venue with its address" do
    assert_equal({
      "name" => "Acme Office",
      "url" => "https://acme.example.org/office",
      "instructions" => "Ring the bell",
      "accessibility" => {"wheelchair" => true, "elevators" => false, "accessible_restrooms" => false},
      "nearby" => {"public_transport" => "U3"},
      "maps" => {"google" => "https://maps.google.com/?q=acme"},
      "address" => {
        "street" => "Main Street 1",
        "postal_code" => "80333",
        "city" => "Munich",
        "region" => "BY",
        "country_code" => "DE",
        "country" => "Germany",
        "display" => "Main Street 1, 80333 Munich, Germany"
      },
      "coordinates" => {"latitude" => 48.1, "longitude" => 11.5}
    }, read("data/munich-rubyshift/meetup-2025-07-17/venue.yml"))
  end

  test "writes the talks as the API has them, with what RubyEvents needs or leaves out" do
    hotwire, bogus = read("data/munich-rubyshift/meetup-2025-07-17/videos.yml")

    assert_equal({
      "id" => "hotwire-native",
      "title" => "Hotwire Native",
      "language" => "English",
      "description" => "About Hotwire",
      "announced_at" => "2025-07-01",
      "additional_resources" => [{"type" => "repo", "name" => "GitHub", "url" => "https://github.com/acme/hotwire"}],
      "date" => "2025-07-17",
      "speakers" => ["Kuba Kuźma"],
      "video_provider" => "not_recorded",
      "video_id" => "hotwire-native"
    }, hotwire)

    assert_equal({
      "id" => "bogus",
      "title" => "Bogus",
      "kind" => "not-a-kind",
      "language" => "German",
      "description" => "",
      "date" => "2025-07-17",
      "speakers" => ["Bea Builder", "Nina Newcomer"],
      "video_provider" => "not_recorded",
      "video_id" => "bogus"
    }, bogus)
  end

  test "marks the talks of an upcoming event as scheduled" do
    talk, = read("data/munich-rubyshift/meetup-2025-07-24/videos.yml")

    assert_equal ["scheduled", "future-talk"], talk.values_at("video_provider", "video_id")
  end

  test "keeps the kind talk where the title suggests another kind" do
    talk, = read("data/munich-rubyshift/meetup-2025-07-24/videos.yml")

    assert_equal "talk", talk["kind"]
  end

  test "writes involvements, sponsors and CFPs" do
    directory = "data/munich-rubyshift/meetup-2025-07-17"

    assert_equal [
      {"name" => "Organizer", "users" => ["Bea Builder"], "organizations" => ["Acme"]},
      {"name" => "Chef", "users" => ["Nina Newcomer"]}
    ], read("#{directory}/involvements.yml")

    assert_equal [{"tiers" => [{
      "name" => "Gold",
      "level" => 1,
      "sponsors" => [{"slug" => "acme", "name" => "Acme", "website" => "https://acme.example.org", "logo_url" => "https://munich-rubyshift.org/logos/acme.png", "badge" => "Venue"}]
    }]}], read("#{directory}/sponsors.yml")

    assert_equal [
      {"name" => "Call for Proposals", "open_date" => "2025-06-01", "link" => "https://munich-rubyshift.org/cfps/meetup-2025-07-17-cfp"}
    ], read("#{directory}/cfp.yml")

    %w[involvements sponsors cfp].each { |list| assert_not @root.join("data/munich-rubyshift/meetup-2025-07-24/#{list}.yml").exist? }
  end

  test "replaces a speaker with the API's person, keeping only the aliases" do
    assert_equal <<~YAML, @root.join("data/speakers.yml").read
      ---
      - name: "Bea Builder"
        github: "bea"
        slug: "bea-builder"
        twitter: "bea_tweets"
        aliases:
          - name: "Bea B."
            slug: "bea-b"
      - name: "Kuba Kuźma"
        github: ""
        slug: "kuba-kuzma"
        aliases:
          - name: "Kuba Kuzma"
            slug: "kuba-kuzma"
      - name: "Nina Newcomer"
        github: "nina"
        slug: "nina-newcomer"
      - name: "Sam Same"
        github: "sam-one"
        slug: "sam-same"
      - name: 'Untouched Person'
        github: ""
        slug: "untouched-person"
    YAML

    assert_equal [
      "speakers.yml: updated Bea Builder",
      "speakers.yml: renamed Kuba Kuzma to Kuba Kuźma",
      "speakers.yml: added Nina Newcomer",
      "speakers.yml: left Sam Same alone, GitHub sam-one there and sam-two in the API"
    ], @report.grep(/speakers.yml/)
  end

  private

  def write(path, content)
    @root.join(path).dirname.mkpath
    @root.join(path).write(content)
  end

  def read(path)
    Yerba.parse_file(@root.join(path).to_s).then { |document| document.sequence? ? document.to_a : document.to_h }
  end

  def stub_api
    stub_document("/people.json", data: [bea, kuba], links: {next: "#{API}/people.json?page=2"})
    stub_document("/people.json?page=2", data: [nina, sam], links: {next: nil})
    stub_document("/organizations.json", data: [acme], links: {next: nil})
    stub_document("/cities.json", data: [munich], links: {next: nil})
    stub_document("/series.json", data: [series], links: {next: nil})
    stub_document("/events/e1.json", data: july, included: july_records)
    stub_document("/events/e2.json", data: july_again, included: [talk("t3", slug: "future-talk", title: "Workshop: Future", description: "", speakers: [nina])])
  end

  def stub_document(path, **document)
    stub_request(:get, "#{API}#{path}").to_return(body: {jsonapi: {version: "1.1"}, **document}.to_json, headers: {"Content-Type" => "application/json"})
  end

  def series
    resource("series", "s1",
      {slug: "munich-rubyshift", name: "Munich Rubyshift", kind: "meetup", language_code: "en", time_zone: "Europe/Berlin", twitter_username: nil,
       meetup: "https://www.meetup.com/munich-rubyshift/", frequency: "quarterly", discord: "https://discord.gg/abc", inactive: false},
      events: [identifier("events", "e1"), identifier("events", "e2")])
  end

  def july
    resource("events", "e1",
      event_attributes(slug: "meetup-2025-07-17", title: "Ruby Meetup July 2025", attendance_mode: "hybrid", start_date: "2025-07-17", start_time: "19:00",
        description: "Line one\n\nLine two", twitter_username: "muc_rubyshift", meetup: "https://www.meetup.com/Munich-Rubyshift", participants_count: 12),
      series: identifier("series", "s1"), venue: identifier("venues", "v1"), talks: [identifier("talks", "t1"), identifier("talks", "t2")],
      sponsor_tiers: [identifier("sponsor_tiers", "st1")], involvements: %w[i1 i2 i3].map { |id| identifier("involvements", id) }, cfps: [identifier("cfps", "c1")])
  end

  def july_again
    resource("events", "e2",
      event_attributes(slug: "meetup-2025-07-24", title: "Munich Rubyshift Meetup July 24, 2025", status: "cancelled", attendance_mode: "in_person", start_date: "2025-07-24"),
      series: identifier("series", "s1"), venue: nil, talks: [identifier("talks", "t3")], sponsor_tiers: [], involvements: [], cfps: [])
  end

  def july_records
    [
      resource("venues", "v1",
        {slug: "acme-office", name: "Acme Office", website: "https://acme.example.org/office", description: nil, instructions: "Ring the bell",
         accessibility_wheelchair: true, accessibility_elevators: false, accessibility_restrooms: false, accessibility_notes: nil,
         nearby_public_transport: "U3", nearby_parking: nil, map: {google_url: "https://maps.google.com/?q=acme", apple_url: nil, openstreetmap_url: nil}},
        address: identifier("addresses", "a1"), organization: identifier("organizations", "o1")),
      resource("addresses", "a1", {slug: "main-street-1", street: "Main Street 1", zip_code: "80333", coordinates: {latitude: 48.1, longitude: 11.5}}, city: identifier("cities", "c1")),
      talk("t1", slug: "hotwire-native", title: "Hotwire Native", description: "About Hotwire", announced_on: "2025-07-01",
        additional_resources: [{kind: "repo", name: "GitHub", title: nil, url: "https://github.com/acme/hotwire"}], speakers: [kuba]),
      talk("t2", slug: "bogus", title: "Bogus", kind: "not-a-kind", language_code: "de", speakers: [bea, nina]),
      resource("sponsor_tiers", "st1", {slug: "gold", name: "Gold", level: 1, description: nil}, sponsorships: [identifier("sponsorships", "sp1")]),
      resource("sponsorships", "sp1", {badge: "Venue"}, organization: identifier("organizations", "o1")),
      resource("involvements", "i1", {role: "Organizer"}, entity: identifier("people", "p1")),
      resource("involvements", "i2", {role: "Organizer"}, entity: identifier("organizations", "o1")),
      resource("involvements", "i3", {role: "Chef"}, entity: identifier("people", "p3")),
      resource("cfps", "c1", {slug: "meetup-2025-07-17-cfp", name: "Call for Proposals", open_date: "2025-06-01", close_date: nil, external_url: nil})
    ]
  end

  def event_attributes(**attributes)
    {slug: nil, title: nil, kind: "meetup", status: nil, attendance_mode: "in_person", start_date: nil, start_time: nil, end_date: nil, end_time: nil,
     date_precision: nil, announced_on: nil, description: nil, tickets_url: nil, website: nil, twitter_username: nil, mastodon: nil, github: nil,
     meetup: nil, luma: nil, participants_count: 0}.merge(attributes)
  end

  def talk(id, speakers:, **attributes)
    resource("talks", id,
      {slug: nil, title: nil, kind: "talk", language_code: "en", description: nil, slides_url: nil, announced_on: nil, additional_resources: []}.merge(attributes),
      speakers: speakers.map { |person| identifier("people", person[:id]) })
  end

  def bea = person("p1", slug: "bea-builder", name: "Bea Builder", github_username: "bea", twitter_username: "bea_tweets", meetup_id: "123", avatar_url: "/avatars/bea.png")

  def kuba = person("p2", slug: "kuba-kuzma", name: "Kuba Kuźma")

  def nina = person("p3", slug: "nina-newcomer", name: "Nina Newcomer", github_username: "nina")

  def sam = person("p4", slug: "sam-same-munich", name: "Sam Same", github_username: "sam-two")

  def person(id, **attributes)
    resource("people", id, {slug: nil, name: nil, website: nil, github_username: nil, twitter_username: nil, mastodon: nil, bluesky_handle: nil,
                            linkedin_username: nil, speakerdeck_username: nil, meetup_id: nil, avatar_url: nil}.merge(attributes))
  end

  def acme
    resource("organizations", "o1", {slug: "acme", name: "Acme", legal_name: "Acme GmbH", website: "https://acme.example.org", logo_url: "/logos/acme.png"})
  end

  def munich
    resource("cities", "c1", {slug: "munich", name: "Munich", state_code: "BY", country_code: "DE", coordinates: {latitude: 48.13, longitude: 11.58}})
  end

  def resource(type, id, attributes, **relationships)
    {type: type, id: id, attributes: attributes, relationships: relationships.transform_values { |data| {data: data} }}.compact_blank
  end

  def identifier(type, id)
    {type: type, id: id}
  end
end
