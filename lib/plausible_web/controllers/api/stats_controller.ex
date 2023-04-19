defmodule PlausibleWeb.Api.StatsController do
  use PlausibleWeb, :controller
  use Plausible.Repo
  use Plug.ErrorHandler
  alias Plausible.Stats
  alias Plausible.Stats.{Query, Filters, Comparisons}

  require Logger

  @doc """
  Returns a time-series based on given parameters.

  ## Parameters

  This API accepts the following parameters:

    * `period` - x-axis of the graph, e.g. `12mo`, `day`, `custom`.

    * `metric` - y-axis of the graph, e.g. `visits`, `visitors`, `pageviews`.
      See the Stats API ["Metrics"](https://plausible.io/docs/stats-api#metrics)
      section for more details. Defaults to `visitors`.

    * `interval` - granularity of the time-series data. You can think of it as
      a `GROUP BY` clause. Possible values are `minute`, `hour`, `date`, `week`,
      and `month`. The default depends on the `period` parameter. Check
      `Plausible.Query.from/2` for each default.

    * `filters` - optional filters to drill down data. See the Stats API
      ["Filtering"](https://plausible.io/docs/stats-api#filtering) section for
      more details.

    * `with_imported` - boolean indicating whether to include Google Analytics
      imported data or not. Defaults to `false`.

  Full example:
  ```elixir
  %{
    "from" => "2021-09-06",
    "interval" => "month",
    "metric" => "visitors",
    "period" => "custom",
    "to" => "2021-12-13"
  }
  ```

  ## Response

  Returns a map with the following keys:

    * `plot` - list of values for the requested metric representing the y-axis
      of the graph.

    * `labels` - list of date times representing the x-axis of the graph.

    * `present_index` - index of the element representing the current date in
      `labels` and `plot` lists.

    * `interval` - the interval used for querying.

    * `with_imported` - boolean indicating whether the Google Analytics data
      was queried or not.

    * `imported_source` - the source of the imported data, when applicable.
      Currently only Google Analytics is supported.

    * `full_intervals` - map of dates indicating whether the interval has been
      cut off by the requested date range or not. For example, if looking at a
      month week-by-week, some weeks may be cut off by the month boundaries.
      It's useful to adjust the graph display slightly in case the interval is
      not 'full' so that the user understands why the numbers might be lower for
      those partial periods.

  Full example:
  ```elixir
  %{
    "full_intervals" => %{
      "2021-09-01" => false,
      "2021-10-01" => true,
      "2021-11-01" => true,
      "2021-12-01" => false
    },
    "imported_source" => nil,
    "interval" => "month",
    "labels" => ["2021-09-01", "2021-10-01", "2021-11-01", "2021-12-01"],
    "plot" => [0, 0, 0, 0],
    "present_index" => nil,
    "with_imported" => false
  }
  ```

  """
  def main_graph(conn, params) do
    site = conn.assigns[:site]

    with :ok <- validate_params(params) do
      query = Query.from(site, params) |> Filters.add_prefix()

      selected_metric =
        if !params["metric"] || params["metric"] == "conversions" do
          :visitors
        else
          String.to_existing_atom(params["metric"])
        end

      timeseries_query =
        if query.period == "realtime" do
          %Query{query | period: "30m"}
        else
          query
        end

      timeseries_result = Stats.timeseries(site, timeseries_query, [selected_metric])

      comparison_opts = parse_comparison_opts(params)

      comparison_result =
        case Comparisons.compare(site, query, params["comparison"], comparison_opts) do
          {:ok, comparison_query} -> Stats.timeseries(site, comparison_query, [selected_metric])
          {:error, :not_supported} -> nil
        end

      labels = label_timeseries(timeseries_result, comparison_result)
      present_index = present_index_for(site, query, labels)
      full_intervals = build_full_intervals(query, labels)

      json(conn, %{
        plot: plot_timeseries(timeseries_result, selected_metric),
        labels: labels,
        comparison_plot: comparison_result && plot_timeseries(comparison_result, selected_metric),
        comparison_labels: comparison_result && label_timeseries(comparison_result, nil),
        present_index: present_index,
        interval: query.interval,
        with_imported: query.include_imported,
        imported_source: site.imported_data && site.imported_data.source,
        full_intervals: full_intervals
      })
    else
      {:error, message} when is_binary(message) -> bad_request(conn, message)
    end
  end

  defp plot_timeseries(timeseries, metric) do
    Enum.map(timeseries, fn row -> row[metric] || 0 end)
  end

  defp label_timeseries(main_result, nil) do
    Enum.map(main_result, & &1.date)
  end

  @blank_value "__blank__"
  defp label_timeseries(main_result, comparison_result) do
    blanks_to_fill = Enum.count(comparison_result) - Enum.count(main_result)

    if blanks_to_fill > 0 do
      blanks = List.duplicate(@blank_value, blanks_to_fill)
      Enum.map(main_result, & &1.date) ++ blanks
    else
      Enum.map(main_result, & &1.date)
    end
  end

  defp build_full_intervals(%{interval: "week", date_range: range}, labels) do
    for label <- labels, into: %{} do
      interval_start = Timex.beginning_of_week(label)
      interval_end = Timex.end_of_week(label)

      within_interval? = Enum.member?(range, interval_start) && Enum.member?(range, interval_end)

      {label, within_interval?}
    end
  end

  defp build_full_intervals(%{interval: "month", date_range: range}, labels) do
    for label <- labels, into: %{} do
      interval_start = Timex.beginning_of_month(label)
      interval_end = Timex.end_of_month(label)

      within_interval? = Enum.member?(range, interval_start) && Enum.member?(range, interval_end)

      {label, within_interval?}
    end
  end

  defp build_full_intervals(_query, _labels) do
    nil
  end

  def top_stats(conn, params) do
    site = conn.assigns[:site]

    with :ok <- validate_params(params) do
      query = Query.from(site, params) |> Filters.add_prefix()

      comparison_mode = params["comparison"] || "previous_period"
      comparison_opts = parse_comparison_opts(params)

      comparison_query =
        case Stats.Comparisons.compare(site, query, comparison_mode, comparison_opts) do
          {:ok, query} -> query
          {:error, _cause} -> nil
        end

      {top_stats, sample_percent} = fetch_top_stats(site, query, comparison_query)

      json(conn, %{
        top_stats: top_stats,
        interval: query.interval,
        sample_percent: sample_percent,
        with_imported: query.include_imported,
        imported_source: site.imported_data && site.imported_data.source,
        comparing_from: comparison_query && comparison_query.date_range.first,
        comparing_to: comparison_query && comparison_query.date_range.last,
        from: query.date_range.first,
        to: query.date_range.last
      })
    else
      {:error, message} when is_binary(message) -> bad_request(conn, message)
    end
  end

  defp present_index_for(site, query, dates) do
    case query.interval do
      "hour" ->
        current_date =
          Timex.now(site.timezone)
          |> Timex.format!("{YYYY}-{0M}-{0D} {h24}:00:00")

        Enum.find_index(dates, &(&1 == current_date))

      "date" ->
        current_date =
          Timex.now(site.timezone)
          |> Timex.to_date()

        Enum.find_index(dates, &(&1 == current_date))

      "week" ->
        current_date =
          Timex.now(site.timezone)
          |> Timex.to_date()
          |> date_or_weekstart(query)

        Enum.find_index(dates, &(&1 == current_date))

      "month" ->
        current_date =
          Timex.now(site.timezone)
          |> Timex.to_date()
          |> Timex.beginning_of_month()

        Enum.find_index(dates, &(&1 == current_date))

      "minute" ->
        current_date =
          Timex.now(site.timezone)
          |> Timex.format!("{YYYY}-{0M}-{0D} {h24}:{0m}:00")

        Enum.find_index(dates, &(&1 == current_date))
    end
  end

  defp date_or_weekstart(date, query) do
    weekstart = Timex.beginning_of_week(date)

    if Enum.member?(query.date_range, weekstart) do
      weekstart
    else
      date
    end
  end

  defp fetch_top_stats(
         site,
         %Query{period: "realtime", filters: %{"event:goal" => _goal}} = query,
         _comparison_query
       ) do
    query_30m = %Query{query | period: "30m"}

    %{
      visitors: %{value: unique_conversions},
      events: %{value: total_conversions}
    } = Stats.aggregate(site, query_30m, [:visitors, :events])

    stats = [
      %{
        name: "Current visitors",
        value: Stats.current_visitors(site)
      },
      %{
        name: "Unique conversions (last 30 min)",
        value: unique_conversions
      },
      %{
        name: "Total conversions (last 30 min)",
        value: total_conversions
      }
    ]

    {stats, 100}
  end

  defp fetch_top_stats(site, %Query{period: "realtime"} = query, _comparison_query) do
    query_30m = %Query{query | period: "30m"}

    %{
      visitors: %{value: visitors},
      pageviews: %{value: pageviews}
    } = Stats.aggregate(site, query_30m, [:visitors, :pageviews])

    stats = [
      %{
        name: "Current visitors",
        value: Stats.current_visitors(site)
      },
      %{
        name: "Unique visitors (last 30 min)",
        value: visitors
      },
      %{
        name: "Pageviews (last 30 min)",
        value: pageviews
      }
    ]

    {stats, 100}
  end

  defp fetch_top_stats(site, %Query{filters: %{"event:goal" => _goal}} = query, comparison_query) do
    total_q = Query.remove_event_filters(query, [:goal, :props])

    {prev_converted_visitors, prev_completions} =
      if comparison_query do
        %{visitors: %{value: prev_converted_visitors}, events: %{value: prev_completions}} =
          Stats.aggregate(site, comparison_query, [:visitors, :events])

        {prev_converted_visitors, prev_completions}
      else
        {nil, nil}
      end

    prev_unique_visitors =
      if comparison_query do
        site
        |> Stats.aggregate(comparison_query, [:visitors])
        |> get_in([:visitors, :value])
      else
        nil
      end

    %{
      visitors: %{value: unique_visitors}
    } = Stats.aggregate(site, total_q, [:visitors])

    %{
      visitors: %{value: converted_visitors},
      events: %{value: completions}
    } = Stats.aggregate(site, query, [:visitors, :events])

    conversion_rate = calculate_cr(unique_visitors, converted_visitors)
    prev_conversion_rate = calculate_cr(prev_unique_visitors, prev_converted_visitors)

    stats = [
      %{
        name: "Unique visitors",
        value: unique_visitors,
        comparison_value: prev_unique_visitors,
        change: percent_change(prev_unique_visitors, unique_visitors)
      },
      %{
        name: "Unique conversions",
        value: converted_visitors,
        comparison_value: prev_converted_visitors,
        change: percent_change(prev_converted_visitors, converted_visitors)
      },
      %{
        name: "Total conversions",
        value: completions,
        comparison_value: prev_completions,
        change: percent_change(prev_completions, completions)
      },
      %{
        name: "Conversion rate",
        value: conversion_rate,
        comparison_value: prev_conversion_rate,
        change: percent_change(prev_conversion_rate, conversion_rate)
      }
    ]

    {stats, 100}
  end

  defp fetch_top_stats(site, query, comparison_query) do
    metrics =
      if query.filters["event:page"] do
        [
          :visitors,
          :visits,
          :pageviews,
          :views_per_visit,
          :bounce_rate,
          :time_on_page,
          :sample_percent
        ]
      else
        [
          :visitors,
          :visits,
          :pageviews,
          :views_per_visit,
          :bounce_rate,
          :visit_duration,
          :sample_percent
        ]
      end

    current_results = Stats.aggregate(site, query, metrics)
    prev_results = comparison_query && Stats.aggregate(site, comparison_query, metrics)

    stats =
      [
        top_stats_entry(current_results, prev_results, "Unique visitors", :visitors),
        top_stats_entry(current_results, prev_results, "Total visits", :visits),
        top_stats_entry(current_results, prev_results, "Total pageviews", :pageviews),
        top_stats_entry(current_results, prev_results, "Views per visit", :views_per_visit),
        top_stats_entry(current_results, prev_results, "Bounce rate", :bounce_rate),
        top_stats_entry(current_results, prev_results, "Visit duration", :visit_duration),
        top_stats_entry(current_results, prev_results, "Time on page", :time_on_page)
      ]
      |> Enum.filter(& &1)

    {stats, current_results[:sample_percent][:value]}
  end

  defp top_stats_entry(current_results, prev_results, name, key) do
    if current_results[key] do
      value = get_in(current_results, [key, :value])
      prev_value = get_in(prev_results, [key, :value])
      change = prev_value && calculate_change(key, prev_value, value)

      %{name: name, value: value, comparison_value: prev_value, change: change}
    end
  end

  defp calculate_change(:bounce_rate, old_count, new_count) do
    if old_count > 0, do: new_count - old_count
  end

  defp calculate_change(_metric, old_count, new_count) do
    percent_change(old_count, new_count)
  end

  defp percent_change(nil, _new_count), do: nil

  defp percent_change(old_count, new_count) do
    cond do
      old_count == 0 and new_count > 0 ->
        100

      old_count == 0 and new_count == 0 ->
        0

      true ->
        round((new_count - old_count) / old_count * 100)
    end
  end

  def sources(conn, params) do
    site = conn.assigns[:site]

    query =
      Query.from(site, params)
      |> Filters.add_prefix()

    pagination = parse_pagination(params)

    metrics =
      if params["detailed"], do: [:visitors, :bounce_rate, :visit_duration], else: [:visitors]

    res =
      Stats.breakdown(site, query, "visit:source", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :source, "visit:source")
      |> transform_keys(%{source: :name})

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        res
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        res |> to_csv([:name, :visitors, :bounce_rate, :visit_duration])
      end
    else
      json(conn, res)
    end
  end

  def utm_mediums(conn, params) do
    site = conn.assigns[:site]

    query =
      Query.from(site, params)
      |> Filters.add_prefix()

    pagination = parse_pagination(params)

    metrics = [:visitors, :bounce_rate, :visit_duration]

    res =
      Stats.breakdown(site, query, "visit:utm_medium", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :utm_medium, "visit:utm_medium")
      |> transform_keys(%{utm_medium: :name})

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        res
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        res |> to_csv([:name, :visitors, :bounce_rate, :visit_duration])
      end
    else
      json(conn, res)
    end
  end

  def utm_campaigns(conn, params) do
    site = conn.assigns[:site]

    query =
      Query.from(site, params)
      |> Filters.add_prefix()

    pagination = parse_pagination(params)

    metrics = [:visitors, :bounce_rate, :visit_duration]

    res =
      Stats.breakdown(site, query, "visit:utm_campaign", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :utm_campaign, "visit:utm_campaign")
      |> transform_keys(%{utm_campaign: :name})

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        res
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        res |> to_csv([:name, :visitors, :bounce_rate, :visit_duration])
      end
    else
      json(conn, res)
    end
  end

  def utm_contents(conn, params) do
    site = conn.assigns[:site]

    query =
      Query.from(site, params)
      |> Filters.add_prefix()

    pagination = parse_pagination(params)
    metrics = [:visitors, :bounce_rate, :visit_duration]

    res =
      Stats.breakdown(site, query, "visit:utm_content", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :utm_content, "visit:utm_content")
      |> transform_keys(%{utm_content: :name})

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        res
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        res |> to_csv([:name, :visitors, :bounce_rate, :visit_duration])
      end
    else
      json(conn, res)
    end
  end

  def utm_terms(conn, params) do
    site = conn.assigns[:site]

    query =
      Query.from(site, params)
      |> Filters.add_prefix()

    pagination = parse_pagination(params)
    metrics = [:visitors, :bounce_rate, :visit_duration]

    res =
      Stats.breakdown(site, query, "visit:utm_term", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :utm_term, "visit:utm_term")
      |> transform_keys(%{utm_term: :name})

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        res
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        res |> to_csv([:name, :visitors, :bounce_rate, :visit_duration])
      end
    else
      json(conn, res)
    end
  end

  def utm_sources(conn, params) do
    site = conn.assigns[:site]

    query =
      Query.from(site, params)
      |> Filters.add_prefix()

    pagination = parse_pagination(params)

    metrics = [:visitors, :bounce_rate, :visit_duration]

    res =
      Stats.breakdown(site, query, "visit:utm_source", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :utm_source, "visit:utm_source")
      |> transform_keys(%{utm_source: :name})

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        res
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        res |> to_csv([:name, :visitors, :bounce_rate, :visit_duration])
      end
    else
      json(conn, res)
    end
  end

  def referrer_drilldown(conn, %{"referrer" => "Google"} = params) do
    site = conn.assigns[:site] |> Repo.preload(:google_auth)

    query =
      Query.from(site, params)
      |> Query.put_filter("source", "Google")
      |> Filters.add_prefix()

    search_terms =
      if site.google_auth && site.google_auth.property && !query.filters["goal"] do
        google_api().fetch_stats(site, query, params["limit"] || 9)
      end

    %{:visitors => %{value: total_visitors}} = Stats.aggregate(site, query, [:visitors])

    user_id = get_session(conn, :current_user_id)
    is_admin = user_id && Plausible.Sites.has_admin_access?(user_id, site)

    case search_terms do
      nil ->
        json(conn, %{not_configured: true, is_admin: is_admin, total_visitors: total_visitors})

      {:ok, terms} ->
        json(conn, %{search_terms: terms, total_visitors: total_visitors})

      {:error, _} ->
        conn
        |> put_status(502)
        |> json(%{
          not_configured: true,
          is_admin: is_admin,
          total_visitors: total_visitors
        })
    end
  end

  def referrer_drilldown(conn, %{"referrer" => referrer} = params) do
    site = conn.assigns[:site]

    query =
      Query.from(site, params)
      |> Query.put_filter("source", referrer)
      |> Filters.add_prefix()

    pagination = parse_pagination(params)

    metrics =
      if params["detailed"], do: [:visitors, :bounce_rate, :visit_duration], else: [:visitors]

    referrers =
      Stats.breakdown(site, query, "visit:referrer", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :referrer, "visit:referrer")
      |> transform_keys(%{referrer: :name})
      |> Enum.map(&Map.drop(&1, [:visits]))

    %{:visitors => %{value: total_visitors}} = Stats.aggregate(site, query, [:visitors])
    json(conn, %{referrers: referrers, total_visitors: total_visitors})
  end

  def pages(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()

    metrics =
      if params["detailed"],
        do: [:visitors, :pageviews, :bounce_rate, :time_on_page],
        else: [:visitors]

    pagination = parse_pagination(params)

    pages =
      Stats.breakdown(site, query, "event:page", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :page, "event:page")
      |> transform_keys(%{page: :name})

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        pages
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        pages |> to_csv([:name, :visitors, :pageviews, :bounce_rate, :time_on_page])
      end
    else
      json(conn, pages)
    end
  end

  def entry_pages(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    pagination = parse_pagination(params)
    metrics = [:visitors, :visits, :visit_duration]

    entry_pages =
      Stats.breakdown(site, query, "visit:entry_page", metrics, pagination)
      |> maybe_add_cr(site, query, pagination, :entry_page, "visit:entry_page")
      |> transform_keys(%{
        entry_page: :name,
        visitors: :unique_entrances,
        visits: :total_entrances
      })

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        entry_pages
        |> transform_keys(%{unique_entrances: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        entry_pages |> to_csv([:name, :unique_entrances, :total_entrances, :visit_duration])
      end
    else
      json(conn, entry_pages)
    end
  end

  def exit_pages(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    {limit, page} = parse_pagination(params)
    metrics = [:visitors, :visits]

    exit_pages =
      Stats.breakdown(site, query, "visit:exit_page", metrics, {limit, page})
      |> maybe_add_cr(site, query, {limit, page}, :exit_page, "visit:exit_page")
      |> transform_keys(%{
        exit_page: :name,
        visitors: :unique_exits,
        visits: :total_exits
      })

    pages = Enum.map(exit_pages, & &1[:name])

    total_visits_query =
      Query.put_filter(query, "event:page", {:member, pages})
      |> Query.put_filter("event:name", {:is, "pageview"})

    exit_pages =
      if !Query.has_event_filters?(query) do
        total_pageviews =
          Stats.breakdown(site, total_visits_query, "event:page", [:pageviews], {limit, 1})

        Enum.map(exit_pages, fn exit_page ->
          exit_rate =
            case Enum.find(total_pageviews, &(&1[:page] == exit_page[:name])) do
              %{pageviews: pageviews} ->
                Float.floor(exit_page[:total_exits] / pageviews * 100)

              nil ->
                nil
            end

          Map.put(exit_page, :exit_rate, exit_rate)
        end)
      else
        exit_pages
      end

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        exit_pages
        |> transform_keys(%{unique_exits: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        exit_pages |> to_csv([:name, :unique_exits, :total_exits, :exit_rate])
      end
    else
      json(conn, exit_pages)
    end
  end

  def countries(conn, params) do
    site = conn.assigns[:site]
    query = site |> Query.from(params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    countries =
      Stats.breakdown(site, query, "visit:country", [:visitors], pagination)
      |> maybe_add_cr(site, query, {300, 1}, :country, "visit:country")
      |> transform_keys(%{country: :code})
      |> maybe_add_percentages(query)

    if params["csv"] do
      countries =
        countries
        |> Enum.map(fn country ->
          country_info = get_country(country[:code])
          Map.put(country, :name, country_info.name)
        end)

      if Map.has_key?(query.filters, "event:goal") do
        countries
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        countries |> to_csv([:name, :visitors])
      end
    else
      countries =
        Enum.map(countries, fn row ->
          country = get_country(row[:code])

          if country do
            Map.merge(row, %{
              name: country.name,
              flag: country.flag,
              alpha_3: country.alpha_3,
              code: country.alpha_2
            })
          else
            Map.merge(row, %{
              name: row[:code],
              flag: "",
              alpha_3: "",
              code: ""
            })
          end
        end)

      json(conn, countries)
    end
  end

  def regions(conn, params) do
    site = conn.assigns[:site]
    query = site |> Query.from(params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    regions =
      Stats.breakdown(site, query, "visit:region", [:visitors], pagination)
      |> transform_keys(%{region: :code})
      |> Enum.map(fn region ->
        region_entry = Location.get_subdivision(region[:code])

        if region_entry do
          country_entry = get_country(region_entry.country_code)
          Map.merge(region, %{name: region_entry.name, country_flag: country_entry.flag})
        else
          Logger.warning("Could not find region info - code: #{inspect(region[:code])}")
          Map.merge(region, %{name: region[:code]})
        end
      end)

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        regions
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        regions |> to_csv([:name, :visitors])
      end
    else
      json(conn, regions)
    end
  end

  def cities(conn, params) do
    site = conn.assigns[:site]
    query = site |> Query.from(params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    cities =
      Stats.breakdown(site, query, "visit:city", [:visitors], pagination)
      |> transform_keys(%{city: :code})
      |> Enum.map(fn city ->
        city_info = Location.get_city(city[:code])

        if city_info do
          country_info = get_country(city_info.country_code)

          Map.merge(city, %{
            name: city_info.name,
            country_flag: country_info.flag
          })
        else
          Logger.warning("Could not find city info - code: #{inspect(city[:code])}")

          Map.merge(city, %{name: "N/A"})
        end
      end)

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        cities
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        cities |> to_csv([:name, :visitors])
      end
    else
      json(conn, cities)
    end
  end

  def browsers(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    browsers =
      Stats.breakdown(site, query, "visit:browser", [:visitors], pagination)
      |> maybe_add_cr(site, query, pagination, :browser, "visit:browser")
      |> transform_keys(%{browser: :name})
      |> maybe_add_percentages(query)

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        browsers
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        browsers |> to_csv([:name, :visitors])
      end
    else
      json(conn, browsers)
    end
  end

  def browser_versions(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    versions =
      Stats.breakdown(site, query, "visit:browser_version", [:visitors], pagination)
      |> maybe_add_cr(site, query, pagination, :browser_version, "visit:browser_version")
      |> transform_keys(%{browser_version: :name})
      |> maybe_add_percentages(query)

    json(conn, versions)
  end

  def operating_systems(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    systems =
      Stats.breakdown(site, query, "visit:os", [:visitors], pagination)
      |> maybe_add_cr(site, query, pagination, :os, "visit:os")
      |> transform_keys(%{os: :name})
      |> maybe_add_percentages(query)

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        systems
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        systems |> to_csv([:name, :visitors])
      end
    else
      json(conn, systems)
    end
  end

  def operating_system_versions(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    versions =
      Stats.breakdown(site, query, "visit:os_version", [:visitors], pagination)
      |> maybe_add_cr(site, query, pagination, :os_version, "visit:os_version")
      |> transform_keys(%{os_version: :name})
      |> maybe_add_percentages(query)

    json(conn, versions)
  end

  def screen_sizes(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    sizes =
      Stats.breakdown(site, query, "visit:device", [:visitors], pagination)
      |> maybe_add_cr(site, query, pagination, :device, "visit:device")
      |> transform_keys(%{device: :name})
      |> maybe_add_percentages(query)

    if params["csv"] do
      if Map.has_key?(query.filters, "event:goal") do
        sizes
        |> transform_keys(%{visitors: :conversions})
        |> to_csv([:name, :conversions, :conversion_rate])
      else
        sizes |> to_csv([:name, :visitors])
      end
    else
      json(conn, sizes)
    end
  end

  defp calculate_cr(nil, _converted_visitors), do: nil

  defp calculate_cr(unique_visitors, converted_visitors) do
    if unique_visitors > 0,
      do: Float.round(converted_visitors / unique_visitors * 100, 1),
      else: 0.0
  end

  def conversions(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()

    query =
      if query.period == "realtime" do
        %Query{query | period: "30m"}
      else
        query
      end

    total_q = Query.remove_event_filters(query, [:goal, :props])

    %{visitors: %{value: total_visitors}} = Stats.aggregate(site, total_q, [:visitors])

    prop_names =
      if query.filters["event:goal"] do
        Stats.props(site, query)
      else
        %{}
      end

    conversions =
      Stats.breakdown(site, query, "event:goal", [:visitors, :events], {100, 1})
      |> transform_keys(%{
        goal: :name,
        visitors: :unique_conversions,
        events: :total_conversions
      })
      |> Enum.map(fn goal ->
        goal
        |> Map.put(:prop_names, prop_names[goal[:name]])
        |> Map.put(:conversion_rate, calculate_cr(total_visitors, goal[:unique_conversions]))
        |> format_revenue_metrics()
      end)

    if params["csv"] do
      conversions |> to_csv([:name, :unique_conversions, :total_conversions])
    else
      json(conn, conversions)
    end
  end

  defp format_revenue_metrics(%{average_revenue: %Money{}, total_revenue: %Money{}} = results) do
    %{
      results
      | average_revenue: %{
          short: Money.to_string!(results.average_revenue, format: :short, fractional_digits: 1),
          long: Money.to_string!(results.average_revenue)
        },
        total_revenue: %{
          short: Money.to_string!(results.total_revenue, format: :short, fractional_digits: 1),
          long: Money.to_string!(results.total_revenue)
        }
    }
  end

  defp format_revenue_metrics(results), do: results

  def prop_breakdown(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()
    pagination = parse_pagination(params)

    total_q = Query.remove_event_filters(query, [:goal, :props])

    %{:visitors => %{value: unique_visitors}} = Stats.aggregate(site, total_q, [:visitors])

    prop_name = "event:props:" <> params["prop_name"]

    props =
      Stats.breakdown(site, query, prop_name, [:visitors, :events], pagination)
      |> transform_keys(%{
        params["prop_name"] => :name,
        :events => :total_conversions,
        :visitors => :unique_conversions
      })
      |> Enum.map(fn prop ->
        Map.put(
          prop,
          :conversion_rate,
          calculate_cr(unique_visitors, prop[:unique_conversions])
        )
      end)

    if params["csv"] do
      props
    else
      json(conn, props)
    end
  end

  def all_props_breakdown(conn, params) do
    site = conn.assigns[:site]
    query = Query.from(site, params) |> Filters.add_prefix()

    prop_names =
      if query.filters["event:goal"] do
        {_, {_, goal}} = query.filters["event:goal"]

        Stats.props(site, query)
        |> Map.get(goal, [])
      else
        []
      end

    values =
      prop_names
      |> Enum.map(fn prop ->
        prop_breakdown(conn, Map.put(params, "prop_name", prop))
        |> Enum.map(&Map.put(&1, :prop, prop))
      end)
      |> Enum.concat()

    to_csv(values, [:prop, :name, :unique_conversions, :total_conversions])
  end

  def current_visitors(conn, _) do
    site = conn.assigns[:site]
    json(conn, Stats.current_visitors(site))
  end

  defp google_api(), do: Application.fetch_env!(:plausible, :google_api)

  def handle_errors(conn, %{kind: kind, reason: reason}) do
    json(conn, %{error: Exception.format_banner(kind, reason)})
  end

  def filter_suggestions(conn, params) do
    site = conn.assigns[:site]

    with :ok <- validate_params(params) do
      query =
        Query.from(site, params)
        |> Filters.add_prefix()

      json(
        conn,
        Stats.filter_suggestions(site, query, params["filter_name"], params["q"])
      )
    else
      {:error, message} when is_binary(message) -> bad_request(conn, message)
    end
  end

  defp transform_keys(results, keys_to_replace) do
    Enum.map(results, fn map ->
      Enum.map(map, fn {key, val} ->
        {Map.get(keys_to_replace, key, key), val}
      end)
      |> Enum.into(%{})
    end)
  end

  defp parse_pagination(params) do
    limit = to_int(params["limit"], 9)
    page = to_int(params["page"], 1)
    {limit, page}
  end

  defp to_int(string, default) when is_binary(string) do
    case Integer.parse(string) do
      {i, ""} when is_integer(i) ->
        i

      _ ->
        default
    end
  end

  defp to_int(_, default), do: default

  defp maybe_add_percentages(stat_list, query) do
    if Map.has_key?(query.filters, "event:goal") do
      stat_list
    else
      total = Enum.reduce(stat_list, 0, fn %{visitors: count}, total -> total + count end)

      Enum.map(stat_list, fn stat ->
        Map.put(stat, :percentage, round(stat[:visitors] / total * 100))
      end)
    end
  end

  defp add_cr(list, list_without_goals, key_name) do
    Enum.map(list, fn item ->
      without_goal = Enum.find(list_without_goals, fn s -> s[key_name] === item[key_name] end)

      item
      |> Map.put(:total_visitors, without_goal[:visitors])
      |> Map.put(:conversion_rate, calculate_cr(without_goal[:visitors], item[:visitors]))
    end)
  end

  defp maybe_add_cr([], _site, _query, _pagination, _key_name, _filter_name), do: []

  defp maybe_add_cr(list, site, query, pagination, key_name, filter_name) do
    if Map.has_key?(query.filters, "event:goal") do
      items = Enum.map(list, fn item -> item[key_name] end)

      query_without_goal =
        query
        |> Query.put_filter(filter_name, {:member, items})
        |> Query.remove_event_filters([:goal, :props])

      res_without_goal =
        Stats.breakdown(site, query_without_goal, filter_name, [:visitors], pagination)

      list
      |> add_cr(res_without_goal, key_name)
    else
      list
    end
  end

  defp to_csv(list, headers) do
    list
    |> Enum.map(fn row -> Enum.map(headers, &row[&1]) end)
    |> (fn res -> [headers | res] end).()
    |> CSV.encode()
    |> Enum.join()
  end

  defp get_country(code) do
    case Location.get_country(code) do
      nil ->
        Logger.warning("Could not find country info - code: #{inspect(code)}")

        %Location.Country{
          alpha_2: code,
          alpha_3: "N/A",
          name: code,
          flag: nil
        }

      country ->
        country
    end
  end

  defp validate_params(params) do
    with :ok <- validate_date(params),
         :ok <- validate_interval(params),
         do: validate_interval_granularity(params)
  end

  defp validate_date(params) do
    with %{"date" => date} <- params,
         {:ok, _} <- Date.from_iso8601(date) do
      :ok
    else
      %{} ->
        :ok

      {:error, _reason} ->
        {:error,
         "Failed to parse date argument. Only ISO 8601 dates are allowed, e.g. `2019-09-07`, `2020-01-01`"}
    end
  end

  defp validate_interval(params) do
    with %{"interval" => interval} <- params,
         true <- Plausible.Stats.Interval.valid?(interval) do
      :ok
    else
      %{} ->
        :ok

      false ->
        values = Enum.join(Plausible.Stats.Interval.list(), ", ")
        {:error, "Invalid value for interval. Accepted values are: #{values}"}
    end
  end

  defp validate_interval_granularity(params) do
    with %{"interval" => interval, "period" => period} <- params,
         true <- Plausible.Stats.Interval.valid_for_period?(period, interval) do
      :ok
    else
      %{} ->
        :ok

      false ->
        {:error,
         "Invalid combination of interval and period. Interval must be smaller than the selected period, e.g. `period=day,interval=minute`"}
    end
  end

  defp bad_request(conn, message) do
    conn
    |> put_status(400)
    |> json(%{error: message})
  end

  defp parse_comparison_opts(params) do
    [
      from: params["compare_from"],
      to: params["compare_to"],
      match_day_of_week?: params["match_day_of_week"] == "true"
    ]
  end
end
