#! /usr/bin/env elixir

Mix.install([
  {:phoenix_playground, "~> 0.1.6"},
  {:phoenix_live_dashboard, "~> 0.8"}
])

require Logger

defmodule Streamlog.IndexLive do
  use Phoenix.LiveView
  alias Streamlog.State
  alias Streamlog.Worker

  def mount(_params, _session, socket) do
    if connected?(socket), do: Worker.run()

    {query, regex} = State.get_query_and_regex()

    response =
      socket
      |> stream(:logs, filtered_lines(regex))
      |> assign(:form, to_form(%{"query" => query}))
      |> assign(
        :page_title,
        Application.get_env(:streamlog, :title)
      )

    {:ok, response}
  end

  def handle_info({:line, line}, socket) do
    {_, regex} = State.get_query_and_regex()

    {:noreply,
     if regex == nil or String.match?(line.line, regex) do
       stream_insert(socket, :logs, decorate_line(line, regex), at: 0)
     else
       socket
     end}
  end

  def handle_event("filter", %{"query" => query} = params, socket) do
    State.set(&%{&1 | "query" => query})

    {_, regex} = State.get_query_and_regex()

    {:noreply,
     socket
     |> stream(:logs, filtered_lines(regex), reset: true)
     |> assign(:form, to_form(params))}
  end

  defp decorate_line(log, nil), do: log
  defp decorate_line(log, regex) do
    safe_line =
      log.line
      |> Phoenix.HTML.Engine.encode_to_iodata!()
      |> IO.chardata_to_string()
      |> then(&Regex.replace(regex, &1, "<em>\\1</em>"))

    %{log | :line_decorated => {:safe, safe_line}}
  end

  defp filtered_lines(regex) do
    Worker.list_entries()
    |> Stream.map(&elem(&1, 1))
    |> then(fn lines ->
      if regex == nil or regex == "" do
        lines
      else
        lines
        |> Stream.filter(&String.match?(&1.line, regex))
        |> Stream.map(&decorate_line(&1, regex))
      end
    end)
    |> Enum.sort(:desc)
  end

  attr(:field, Phoenix.HTML.FormField)
  attr(:rest, :global, include: ~w(type))

  def input(assigns) do
    ~H"""
    <input id={@field.id} name={@field.name} value={@field.value} {@rest} />
    """
  end

  def render(assigns) do
    ~H"""
    <.form for={@form} phx-change="filter" >
      <.input type="text" field={@form[:query]} />
    </.form>
    <table>
      <thead>
        <tr>
          <th>timestamp</th>
          <th>-</th>
        </tr>
      </thead>
      <tbody id="log-list" phx-update="stream">
        <tr :for={{id, log} <- @streams.logs} id={id} class={if rem(log.id,2)==0, do: "even", else: "odd"}  >
          <td class="timestamp"><%= log.timestamp %></td>
          <td class="message"><%= log.line_decorated %></td>
        </tr>
      </tbody>
    </table>
    <style>
      :root {
        --color-accent: #118bee15;
      }
      table {
        text-align: left;
        font-family: monospace;
        display: table;
        mi  n-width: 100%;

        td {
          padding-right: 10px;
          border-right: solid 1px #339981;

          &.message {
            text-align: left;
            em {
              background-color: lightyellow;
            }
          }
        }
        tr.odd {
          background-color: var(--color-accent);
        }
      }
    </style>
    """
  end
end

defmodule Streamlog.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {PhoenixPlayground.Layout, :root})
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)

    live("/", Streamlog.IndexLive, :index)
    live_dashboard("/dashboard")
  end
end

defmodule Streamlog.Worker do
  use GenServer
  @topic inspect(__MODULE__)
  @log_table :logs

  def start_link([]) do
    :ets.new(@log_table, [:set, :public, :named_table])
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]), do: {:ok, false}

  def run() do
    GenServer.cast(__MODULE__, :run)
    Phoenix.PubSub.subscribe(PhoenixPlayground.PubSub, @topic)
  end

  @impl true
  def handle_cast(:run, false) do
    :stdio
    |> IO.stream(:line)
    |> Stream.filter(&(String.trim(&1) != ""))
    |> Stream.with_index(1)
    |> Stream.map(&create_log_entry/1)
    |> Stream.each(&:ets.insert(@log_table, {&1.id, &1}))
    |> Stream.each(&notify_subscribers/1)
    |> Stream.run()

    {:noreply, :running}
  end

  def handle_cast(:run, :running), do: {:noreply, :running}

  defp create_log_entry({line, index}),
    do: %{id: index, line: line, timestamp: DateTime.now!("Etc/UTC"), line_decorated: line}

  defp notify_subscribers(line),
    do: Phoenix.PubSub.broadcast(PhoenixPlayground.PubSub, @topic, {:line, line})

  def list_entries(), do: :ets.tab2list(@log_table)
end

defmodule Streamlog.State do
  use Agent

  def start_link(initial_state) do
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  def value, do: Agent.get(__MODULE__, & &1)
  def set(update_fn), do: Agent.update(__MODULE__, &update_fn.(&1))
  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

  def get_query_and_regex do
    query = get("query")

    if query == nil or query == "" do
      {nil, nil}
    else
      case Regex.compile("(#{query})", [:caseless]) do
        {:ok, regex} -> {query, regex}
        _ -> {query, nil}
      end
    end
  end
end

{options, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      title: :string,
      port: :integer,
      open: :boolean
    ]
  )

options =
  Keyword.validate!(options,
    title: "Stream Log",
    port: 5051,
    open: false
  )

Application.put_env(:streamlog, :title, Keyword.fetch!(options, :title))

Logger.info("Streamlog starting with the following options: #{inspect(options)}")

{:ok, _} =
  PhoenixPlayground.start(
    plug: Streamlog.Router,
    live_reload: false,
    child_specs: [
      Streamlog.Worker,
      {Streamlog.State, %{"query" => nil}}
    ],
    open_browser: Keyword.fetch!(options, :open),
    port: Keyword.fetch!(options, :port)
  )
