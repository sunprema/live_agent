defmodule LiveAgent.ComponentTreeParser do
  @moduledoc false

  @doc """
  Parses a rendered LiveView HTML response and returns a component tree map:
    %{view_id: "phx-FgX2abc", components: [...]}

  Uses regex-based scanning — no HTML parser dependency needed.
  Call this in register_before_send where the raw HTML is available.
  """
  def extract(html) do
    %{
      view_id: extract_view_id(html),
      components: extract_components(html)
    }
  end

  # ── View ID ──────────────────────────────────────────────────────────────────

  # The LV root element has data-phx-main="true" and id="phx-...".
  # Attribute order varies so we try both orderings.
  defp extract_view_id(html) do
    cond do
      m = Regex.run(~r/\bdata-phx-main="true"[^>]*\bid="([^"]+)"/, html) ->
        Enum.at(m, 1)

      m = Regex.run(~r/\bid="([^"]+)"[^>]*\bdata-phx-main="true"/, html) ->
        Enum.at(m, 1)

      true ->
        nil
    end
  end

  # ── Components ────────────────────────────────────────────────────────────────

  # Strategy: split the HTML on each `data-phx-component="N"` occurrence.
  # The split result is [pre0, cid1, post1, cid2, post2, ...] where:
  #   pre_i  = text just before the data-phx-component attribute (includes partial opening tag)
  #   post_i = text just after the attribute up to the next component or end of document
  #
  # For dom_id: look in pre_i after the last `<` (same opening tag, before data-phx-component).
  # For events: scan post_i for phx-{event}="name" bindings.
  defp extract_components(html) do
    parts =
      Regex.split(~r/\bdata-phx-component="(\d+)"/, html, include_captures: true)

    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {cid_str, i} when rem(i, 2) == 1 ->
        before_str = Enum.at(parts, i - 1, "")
        after_str = Enum.at(parts, i + 1, "")

        cid = String.to_integer(cid_str)
        tag_context = opening_tag_context(before_str, after_str)

        [
          %{
            cid: cid,
            dom_id: find_attr(tag_context, "id"),
            events: extract_events(after_str)
          }
        ]

      _ ->
        []
    end)
  end

  # Reconstruct the opening tag around the data-phx-component attribute:
  # - take from the last `<` in before_str (partial tag before the attribute)
  # - take up to the first `>` in after_str (rest of tag after the attribute)
  defp opening_tag_context(before_str, after_str) do
    tag_prefix =
      before_str
      |> String.split("<")
      |> List.last()
      |> Kernel.||("")

    tag_suffix =
      after_str
      |> String.split(">")
      |> List.first()
      |> Kernel.||("")

    tag_prefix <> tag_suffix
  end

  defp find_attr(tag_str, attr) do
    case Regex.run(~r/\b#{attr}="([^"]+)"/, tag_str) do
      [_, value] -> value
      _ -> nil
    end
  end

  # ── Events ────────────────────────────────────────────────────────────────────

  @event_pattern ~r/\bphx-(click|change|submit|blur|focus|keyup|keydown)="([^"]+)"/

  defp extract_events(html) do
    Regex.scan(@event_pattern, html)
    |> Enum.map(fn [_, type, name] -> %{type: type, name: name} end)
    |> Enum.uniq_by(fn %{type: t, name: n} -> {t, n} end)
  end
end
