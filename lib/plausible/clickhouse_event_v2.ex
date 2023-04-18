defmodule Plausible.ClickhouseEventV2 do
  @moduledoc """
  Event schema for when NumericIDs migration is complete
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "events_v2" do
    field :name, :string
    field :site_id, Ch.Types.UInt64
    field :hostname, :string
    field :pathname, :string
    field :user_id, Ch.Types.UInt64
    field :session_id, Ch.Types.UInt64
    field :timestamp, :naive_datetime

    field :referrer, :string
    field :referrer_source, :string
    field :utm_medium, :string
    field :utm_source, :string
    field :utm_campaign, :string
    field :utm_content, :string
    field :utm_term, :string

    field :country_code, Ch.Types.FixedString, size: 2
    field :subdivision1_code, :string
    field :subdivision2_code, :string
    field :city_geoname_id, Ch.Types.UInt32

    field :screen_size, :string
    field :operating_system, :string
    field :operating_system_version, :string
    field :browser, :string
    field :browser_version, :string

    field :"meta.key", {:array, :string}
    field :"meta.value", {:array, :string}
    field :monetary_value, Ch.Types.Decimal64, scale: 4

    field :transferred_from, :string
  end

  def new(attrs) do
    %__MODULE__{}
    |> cast(
      attrs,
      [
        :name,
        :site_id,
        :hostname,
        :pathname,
        :user_id,
        :timestamp,
        :operating_system,
        :operating_system_version,
        :browser,
        :browser_version,
        :referrer,
        :referrer_source,
        :utm_medium,
        :utm_source,
        :utm_campaign,
        :utm_content,
        :utm_term,
        :country_code,
        :subdivision1_code,
        :subdivision2_code,
        :city_geoname_id,
        :screen_size,
        :"meta.key",
        :"meta.value",
        :monetary_value
      ],
      empty_values: [nil, ""]
    )
    |> validate_required([:name, :site_id, :hostname, :pathname, :user_id, :timestamp])
  end
end
