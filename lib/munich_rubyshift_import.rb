# frozen_string_literal: true

# Writes the data files of Munich Rubyshift from the JSON:API that the group publishes for RubyEvents.
#
#   bin/update_munich_rubyshift_meetups
#
# The API owns data/munich-rubyshift/, which the import writes from scratch: whatever the API doesn't deliver, like an
# event's old_talk_ids or a schedule.yml, is gone afterwards. Each event goes into the folder named after its slug.
# The people the API lists are merged into data/speakers.yml, where its values win.
#
# The values are written as the API gives them, without checking them against RubyEvents' schemas, so that CI reports
# what RubyEvents doesn't accept yet. Each attribute keeps its name unless RENAMES gives it another.
class MunichRubyshiftImport
  API = "https://munich-rubyshift.org/api/rubyevents-v1"

  # The keys of RubyEvents for the API's attributes, by the API's type of resource, or by the RubyEvents key of a
  # nested value (like "maps"). A key with a dot goes into a nested hash.
  RENAMES = {
    "series" => {"slug" => "id", "time_zone" => "timezone", "language_code" => "language", "inactive" => "ended", "twitter_username" => "twitter", "bluesky_handle" => "bsky"},
    "events" => {"slug" => "id", "twitter_username" => "twitter"},
    "venues" => {
      "website" => "url",
      "map" => "maps",
      "accessibility_wheelchair" => "accessibility.wheelchair",
      "accessibility_elevators" => "accessibility.elevators",
      "accessibility_restrooms" => "accessibility.accessible_restrooms",
      "accessibility_notes" => "accessibility.notes",
      "nearby_public_transport" => "nearby.public_transport",
      "nearby_parking" => "nearby.parking"
    },
    "maps" => {"google_url" => "google", "apple_url" => "apple", "openstreetmap_url" => "openstreetmap"},
    "addresses" => {"zip_code" => "postal_code"},
    "cities" => {"name" => "city", "state_code" => "region"},
    "talks" => {"slug" => "id", "language_code" => "language", "announced_on" => "announced_at"},
    # JSON:API reserves "type".
    "additional_resources" => {"kind" => "type"},
    "involvements" => {"role" => "name"},
    "cfps" => {"external_url" => "link"},
    "people" => {"github_username" => "github", "twitter_username" => "twitter", "bluesky_handle" => "bluesky", "linkedin_username" => "linkedin", "speakerdeck_username" => "speakerdeck"}
  }.freeze

  # Attributes that RubyEvents has no key for, or that the import turns into other values.
  IGNORED = {
    "series" => %w[frequency discord],
    "events" => %w[attendance_mode participants_count],
    "venues" => %w[slug],
    "addresses" => %w[slug coordinates],
    "cities" => %w[slug coordinates],
    "sponsor_tiers" => %w[slug],
    "organizations" => %w[legal_name],
    "cfps" => %w[slug],
    "people" => %w[meetup_id avatar_url]
  }.freeze

  # How RubyEvents writes the values of these keys differently.
  CONVERSIONS = {
    "language" => ->(code) { Language.by_code(code) || code },
    # The API has the path of a logo on its website.
    "logo_url" => ->(path) { URI.join(API, path).to_s }
  }.freeze

  attr_reader :report

  def initialize(root: Rails.root, today: Date.current, client: JsonApi::Client.new(API))
    @root = Pathname.new(root.to_s)
    @today = today
    @client = client
    @report = []
  end

  def run
    fetch.all("series").each { |series| write_series(series) }

    speakers = SpeakerList.new(@root.join("data/speakers.yml"))
    @client.store.all("people").each { |person| log(speakers.merge(attributes_of(person))) }
    speakers.write

    report
  end

  private

  # The global lists, then the document of each event that a series lists.
  def fetch
    %w[people organizations cities series].each { |list| @client.fetch("/#{list}.json") }

    @client.store.all("series").each do |series|
      series.linkage("events").each { |event| @client.fetch("/events/#{event.fetch("id")}.json") }
    end

    @client.store
  end

  def write_series(series)
    directory = @root.join("data", folder(series))
    events = series.related("events")
    before = directory.glob("*/event.yml").map { |file| file.dirname.basename.to_s }
    after = events.map { |event| folder(event) }

    FileUtils.rm_rf(directory)
    write(directory.join("series.yml"), attributes_of(series))
    events.each { |event| write_event(event, series, directory.join(folder(event))) }

    (before - after).each { |stale| log("removed #{directory.basename}/#{stale}") }
    (after - before).each { |new| log("added #{directory.basename}/#{new}") }
  end

  def write_event(event, series, directory)
    venue = event.related("venue")

    write(directory.join("event.yml"), event_record(event, series, venue))
    write(directory.join("venue.yml"), venue && venue_record(venue))
    write(directory.join("videos.yml"), talk_records(event))
    write(directory.join("involvements.yml"), involvement_records(event))
    write(directory.join("sponsors.yml"), sponsor_records(event))
    write(directory.join("cfp.yml"), cfp_records(event))
  end

  # An event in person without a venue has no location, until the API delivers one.
  def event_record(event, series, venue)
    location, coordinates =
      if event["attendance_mode"] == "online"
        ["online", false]
      elsif venue
        address = venue.related("address")
        city = address.related("city")
        [[city["name"], country(city["country_code"])].compact.join(", "), address["coordinates"]]
      end

    record = with_derived(
      attributes_of(event),
      "location" => location,
      "timezone" => series["time_zone"],
      "hybrid" => (true if event["attendance_mode"] == "hybrid"),
      "coordinates" => coordinates
    )
    record = meetup_titled(record, series) if record["kind"] == "meetup" && record["start_date"]

    without_series_socials(record, attributes_of(series))
  end

  # RubyEvents titles a meetup after its group and month, like Static::Validators::MeetupTitle, with the day when the
  # series has more than one event that month. The API's title becomes the subtitle.
  def meetup_titled(record, series)
    date = Date.parse(record["start_date"])
    same_month = series.related("events").count { |other| other["start_date"].to_s.start_with?(date.strftime("%Y-%m")) }
    month = (same_month > 1) ? "#{Date::MONTHNAMES[date.month]} #{date.day}," : Date::MONTHNAMES[date.month]
    title = "#{Static::Validators::MeetupTitle.title_name(attributes_of(series))} #{month} #{date.year}"

    with_derived(record.merge("title" => title), "subtitle" => (record["title"] unless record["title"] == title))
  end

  # RubyEvents keeps a link that an event shares with its series only on the series, compared like
  # Static::Validators::DuplicateSeriesSocials does.
  def without_series_socials(record, series_record)
    same = ->(value) { value.to_s.strip.downcase.delete_prefix("@").delete_suffix("/") }

    Static::Validators::DuplicateSeriesSocials::SOCIAL_FIELDS.each do |field|
      record[field] = nil if record[field].present? && same.call(record[field]) == same.call(series_record[field])
    end

    record
  end

  def venue_record(venue)
    address = venue.related("address")
    city = address.related("city")
    fields = attributes_of(address).merge(attributes_of(city), "country" => country(city["country_code"]))
    display = [fields["street"], [fields["postal_code"], fields["city"]].compact.join(" ").presence, fields["country"]].compact.join(", ")

    attributes_of(venue).merge("address" => fields.merge("display" => display), "coordinates" => address["coordinates"])
  end

  # RubyEvents needs a description and a video for every talk, so a talk without them gets an empty description and a
  # placeholder video until the API delivers them. It wants a kind only where the title suggests another one.
  def talk_records(event)
    event.related("talks").map do |talk|
      record = attributes_of(talk)
      record["kind"] = nil if record["kind"] == "talk" && ::Talk::Kind.from_title(record["title"]).to_s == "talk"

      with_derived(
        record,
        "description" => "",
        "date" => event["start_date"],
        "speakers" => talk.related("speakers").map { |person| person["name"] },
        "video_provider" => upcoming?(event) ? "scheduled" : "not_recorded",
        "video_id" => record["id"]
      )
    end
  end

  def involvement_records(event)
    event.related("involvements").group_by { |involvement| attributes_of(involvement) }.map do |record, involvements|
      people, organizations = involvements.map { |involvement| involvement.related("entity") }.partition { |entity| entity.type == "people" }
      record.merge("users" => people.map { |person| person["name"] }, "organizations" => organizations.map { |organization| organization["name"] })
    end
  end

  def sponsor_records(event)
    tiers = event.related("sponsor_tiers").map do |tier|
      sponsors = tier.related("sponsorships").map { |sponsorship| attributes_of(sponsorship.related("organization")).merge(attributes_of(sponsorship)) }
      attributes_of(tier).merge("sponsors" => sponsors)
    end

    tiers.empty? ? [] : [{"tiers" => tiers}]
  end

  # Without a link of its own, a CFP takes submissions on its page on the group's website.
  def cfp_records(event)
    event.related("cfps").map { |cfp| with_derived(attributes_of(cfp), "link" => URI.join(API, "/cfps/#{cfp["slug"]}").to_s) }
  end

  def attributes_of(resource)
    remap(resource.attributes, resource.type)
  end

  def remap(attributes, type)
    renames = RENAMES.fetch(type, {})

    attributes.except(*IGNORED[type]).each_with_object({}) do |(name, value), record|
      *parents, key = renames.fetch(name, name).split(".")
      parents.reduce(record) { |hash, parent| hash[parent] ||= {} }[key] = convert(key, value)
    end
  end

  def convert(key, value)
    case value
    when Hash then remap(value, key)
    when Array then value.map { |item| convert(key, item) }
    when nil then nil
    else CONVERSIONS.key?(key) ? CONVERSIONS[key].call(value) : value
    end
  end

  # The values the import works out itself, unless the API has its own.
  def with_derived(record, derived)
    record.merge(derived) { |_key, value, derived_value| value.nil? ? derived_value : value }
  end

  # Writes nothing where the API has nothing, like a venue.yml for an event without a venue.
  def write(path, content)
    content = prune(content)
    YAMLWriter.write(path, content) unless empty?(content)
  end

  # Leaves out what the API doesn't know: nil, and the lists and hashes left empty without it.
  def prune(value)
    case value
    when Hash then value.transform_values { |item| prune(item) }.reject { |_key, item| empty?(item) }
    when Array then value.map { |item| prune(item) }.reject { |item| empty?(item) }
    else value
    end
  end

  def empty?(value)
    value.nil? || ((value.is_a?(Hash) || value.is_a?(Array)) && value.empty?)
  end

  # A slug names a folder, so it must not lead out of data/.
  def folder(resource)
    slug = resource["slug"].to_s
    raise ArgumentError, "#{resource.type} #{resource.id} has the slug #{slug.inspect}, which can't name a folder" unless slug.match?(/\A[\w-]+\z/)

    slug
  end

  def country(code)
    code && (Country.find(code)&.name || code)
  end

  # An event without a date yet is still to come.
  def upcoming?(event)
    date = event["end_date"] || event["start_date"]
    date.nil? || Date.parse(date) >= @today
  end

  def log(line)
    report << line if line
  end
end
