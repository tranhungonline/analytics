defimpl Jason.Encoder, for: Plausible.Goal do
  def encode(value, opts) do
    goal_type =
      cond do
        value.event_name -> :event
        value.page_path -> :page
      end

    domain = value.site.domain

    value
    |> Map.put(:goal_type, goal_type)
    |> Map.take([:id, :goal_type, :event_name, :page_path])
    |> Map.put(:domain, domain)
    |> Jason.Encode.map(opts)
  end
end

defmodule Plausible.Goal do
  use Ecto.Schema
  import Ecto.Changeset

  schema "goals" do
    field :event_name, :string
    field :page_path, :string

    belongs_to :site, Plausible.Site

    timestamps()
  end

  def changeset(goal, attrs \\ %{}) do
    goal
    |> cast(attrs, [:site_id, :event_name, :page_path])
    |> validate_required([:site_id])
    |> cast_assoc(:site)
    |> validate_event_name_and_page_path()
    |> update_change(:event_name, &String.trim/1)
    |> update_change(:page_path, &String.trim/1)
  end

  defp validate_event_name_and_page_path(changeset) do
    if validate_page_path(changeset) || validate_event_name(changeset) do
      changeset
    else
      changeset
      |> add_error(:event_name, "this field is required and cannot be blank")
      |> add_error(:page_path, "this field is required and must start with a /")
    end
  end

  defp validate_page_path(changeset) do
    value = get_field(changeset, :page_path)
    value && String.match?(value, ~r/^\/.*/)
  end

  defp validate_event_name(changeset) do
    value = get_field(changeset, :event_name)
    value && String.match?(value, ~r/^.+/)
  end

  def display_name(%__MODULE__{page_path: page_path}) when is_binary(page_path) do
    "Visit " <> page_path
  end

  def display_name(%__MODULE__{event_name: name}) when is_binary(name) do
    name
  end
end
