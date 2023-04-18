defmodule Plausible.Ingestion.Request do
  @moduledoc """
  The %Plausible.Ingestion.Request{} struct stores all needed fields
  to create an event downstream. Pre-eliminary validation is made
  to detect user errors early.
  """

  use Ecto.Schema
  alias Ecto.Changeset

  embedded_schema do
    field :remote_ip, :string
    field :user_agent, :string
    field :event_name, :string
    field :uri, :string
    field :hostname, :string
    field :referrer, :string
    field :domains, {:array, :string}
    field :hash_mode, :string
    field :pathname, :string
    field :props, :map
    field :revenue_source, :map
    field :query_params, :map

    field :timestamp, :naive_datetime
  end

  @type t() :: %__MODULE__{}

  @spec build(Plug.Conn.t(), NaiveDateTime.t()) :: {:ok, t()} | {:error, Changeset.t()}
  @doc """
  Builds and initially validates %Plausible.Ingestion.Request{} struct from %Plug.Conn{}.
  """
  def build(%Plug.Conn{} = conn, now \\ NaiveDateTime.utc_now()) do
    changeset =
      %__MODULE__{}
      |> Changeset.change()
      |> Changeset.put_change(
        :timestamp,
        NaiveDateTime.truncate(now, :second)
      )

    case parse_body(conn) do
      {:ok, request_body} ->
        changeset
        |> put_remote_ip(conn)
        |> put_uri(request_body)
        |> put_hostname()
        |> put_user_agent(conn)
        |> put_request_params(request_body)
        |> put_pathname()
        |> put_query_params()
        |> put_revenue_source(request_body)
        |> map_domains(request_body)
        |> Changeset.validate_required([
          :event_name,
          :hostname,
          :pathname,
          :timestamp
        ])
        |> Changeset.validate_length(:pathname, max: 2000)
        |> Changeset.apply_action(nil)

      {:error, :invalid_json} ->
        {:error, Changeset.add_error(changeset, :request, "Unable to parse request body as json")}
    end
  end

  defp put_remote_ip(changeset, conn) do
    Changeset.put_change(changeset, :remote_ip, PlausibleWeb.RemoteIp.get(conn))
  end

  defp parse_body(conn) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} ->
        {:ok, body, _conn} = Plug.Conn.read_body(conn)

        case Jason.decode(body) do
          {:ok, params} -> {:ok, params}
          _ -> {:error, :invalid_json}
        end

      params ->
        {:ok, params}
    end
  end

  defp put_request_params(changeset, %{} = request_body) do
    Changeset.change(
      changeset,
      event_name: request_body["n"] || request_body["name"],
      referrer: request_body["r"] || request_body["referrer"],
      hash_mode: request_body["h"] || request_body["hashMode"],
      props: parse_props(request_body)
    )
  end

  defp put_pathname(changeset) do
    uri = Changeset.get_field(changeset, :uri)
    hash_mode = Changeset.get_field(changeset, :hash_mode)
    pathname = get_pathname(uri, hash_mode)
    Changeset.put_change(changeset, :pathname, pathname)
  end

  defp map_domains(changeset, %{} = request_body) do
    raw = request_body["d"] || request_body["domain"]
    raw = if is_binary(raw), do: String.trim(raw)

    case raw do
      "" ->
        Changeset.add_error(changeset, :domain, "can't be blank")

      raw when is_binary(raw) ->
        domains =
          raw
          |> String.split(",")
          |> Enum.map(&sanitize_hostname/1)

        Changeset.put_change(changeset, :domains, domains)

      nil ->
        from_uri = sanitize_hostname(Changeset.get_field(changeset, :uri))

        if from_uri do
          Changeset.put_change(changeset, :domains, [from_uri])
        else
          Changeset.add_error(changeset, :domain, "can't be blank")
        end
    end
  end

  @disallowed_schemes ~w(data)
  defp put_uri(changeset, %{} = request_body) do
    with url when is_binary(url) <- request_body["u"] || request_body["url"],
         %URI{} = uri when uri.scheme not in @disallowed_schemes <- URI.parse(url) do
      Changeset.put_change(changeset, :uri, uri)
    else
      nil -> Changeset.add_error(changeset, :url, "is required")
      %URI{} -> Changeset.add_error(changeset, :url, "scheme is not allowed")
      _ -> Changeset.add_error(changeset, :url, "must be a string")
    end
  end

  defp put_hostname(changeset) do
    host =
      case Changeset.get_field(changeset, :uri) do
        %{host: host} when is_binary(host) and host != "" -> host
        _ -> "(none)"
      end

    Changeset.put_change(changeset, :hostname, sanitize_hostname(host))
  end

  defp parse_props(%{} = request_body) do
    raw_props =
      request_body["m"] || request_body["meta"] || request_body["p"] || request_body["props"]

    case maybe_decode_json(raw_props) do
      {:ok, parsed_json} ->
        parsed_json
        |> Enum.filter(&valid_prop_value?/1)
        |> Map.new()

      _error ->
        %{}
    end
  end

  defp maybe_decode_json(raw) when is_map(raw), do: {:ok, raw}

  defp maybe_decode_json(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      _ ->
        :not_a_map
    end
  end

  defp maybe_decode_json(_), do: :bad_format

  defp valid_prop_value?({key, value}) do
    case {key, value} do
      {_key, ""} -> false
      {_key, nil} -> false
      {_key, value} when is_list(value) -> false
      {_key, value} when is_map(value) -> false
      {_key, _value} -> true
    end
  end

  defp put_revenue_source(%Ecto.Changeset{} = changeset, %{} = request_body) do
    with revenue_source <- request_body["revenue"] || request_body["$"],
         {:ok, %{"amount" => _, "currency" => _} = revenue_source} <-
           maybe_decode_json(revenue_source) do
      parse_revenue_source(changeset, revenue_source)
    else
      _any -> changeset
    end
  end

  @valid_currencies Plausible.Goal.valid_currencies()
  defp parse_revenue_source(changeset, %{"amount" => amount, "currency" => currency}) do
    with true <- currency in @valid_currencies,
         {%Decimal{} = amount, _rest} <- parse_decimal(amount),
         %Money{} = amount <- Money.new(currency, amount) do
      Changeset.put_change(changeset, :revenue_source, amount)
    else
      false ->
        Changeset.add_error(changeset, :revenue_source, "currency is not supported or invalid")

      _parse_error ->
        Changeset.add_error(changeset, :revenue_source, "must be a valid number")
    end
  end

  defp parse_decimal(value) do
    case value do
      value when is_binary(value) -> Decimal.parse(value)
      value when is_float(value) -> {Decimal.from_float(value), nil}
      value when is_integer(value) -> {Decimal.new(value), nil}
      _any -> :error
    end
  end

  defp put_query_params(changeset) do
    case Changeset.get_field(changeset, :uri) do
      %{query: query} when is_binary(query) ->
        Changeset.put_change(changeset, :query_params, URI.decode_query(query))

      _any ->
        changeset
    end
  end

  defp put_user_agent(changeset, %Plug.Conn{} = conn) do
    user_agent =
      conn
      |> Plug.Conn.get_req_header("user-agent")
      |> List.first()

    Changeset.put_change(changeset, :user_agent, user_agent)
  end

  defp get_pathname(nil, _hash_mode), do: "/"

  defp get_pathname(uri, hash_mode) do
    pathname =
      (uri.path || "/")
      |> URI.decode()
      |> String.trim_trailing()

    if hash_mode == 1 && uri.fragment do
      pathname <> "#" <> URI.decode(uri.fragment)
    else
      pathname
    end
  end

  @doc """
  Removes the "www" part of a hostname.
  """
  def sanitize_hostname(%URI{host: hostname}) do
    sanitize_hostname(hostname)
  end

  def sanitize_hostname(hostname) when is_binary(hostname) do
    hostname
    |> String.trim()
    |> String.replace_prefix("www.", "")
  end

  def sanitize_hostname(nil) do
    nil
  end
end
