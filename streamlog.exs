#! /usr/bin/env elixir

Mix.install([
  {:phoenix_playground, "~> 0.1.6"},
  {:phoenix_live_dashboard, "~> 0.8"},
  {:ex_sqlean, "~> 0.8.7"},
  {:exqlite, "~> 0.27"}
])

require Logger

defmodule Streamlog.IndexLive do
  use Phoenix.LiveView
  alias Streamlog.State
  alias Streamlog.LogIngester

  def mount(_params, _session, socket) do
    if connected?(socket), do: LogIngester.run()

    {query, _} = State.get_query_and_regex()

    response =
      socket
      |> stream(:logs, filtered_lines())
      |> assign(:form, to_form(%{"query" => query}))
      |> assign(
        :page_title,
        Application.get_env(:streamlog, :title)
      )

    {:ok, response}
  end

  def handle_info({:line, line}, socket) do
    {_, regex} = State.get_query_and_regex()

    {:noreply, if not is_nil(regex) do
     with {:ok, re} <- Regex.compile(regex),
          true <- String.match?(line.line, re) do
       stream_insert(socket, :logs, decorate_line(line, re), at: 0)
     else
       _ -> socket
     end
    else
      stream_insert(socket, :logs, line, at: 0)
    end}
  end

  def handle_event("filter", %{"query" => query} = params, socket) do
    State.set(&%{&1 | "query" => query})

    {:noreply,
     socket
     |> stream(:logs, filtered_lines(), reset: true)
     |> assign(:form, to_form(params))}
  end

  defp decorate_line(log, nil), do: log

  defp decorate_line(log, regex) do
    safe_line =
      log.line
      |> Phoenix.HTML.Engine.encode_to_iodata!()
      |> IO.chardata_to_string()
      |> then(&Regex.replace(regex, &1, "<em>\\0</em>"))

    %{log | :line_decorated => {:safe, safe_line}}
  end

  defp filtered_lines() do
    {regex, compiled_regex} = State.get_query_and_regex()

    LogIngester.list_entries(compiled_regex)
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
        min-width: 100%;

        td {
          padding-right: 10px;
          border-right: solid 1px #339981;

          &.message {
            text-align: left;
            em {
              background-color: yellow;
            }
          }
        }
        tr:nth-child(odd) {
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

defmodule Streamlog.LogIngester do
  use GenServer
  alias Exqlite.Sqlite3
  alias Exqlite.Basic

  @topic inspect(__MODULE__)

  def start_link(init) do
    GenServer.start_link(__MODULE__, init ,name: __MODULE__)
  end

  @impl true
  def init(%{limit: limit}) do
    {:ok, conn = %{db: db}} = Basic.open(":memory:")

    :ok = Basic.enable_load_extension(conn)
    {:ok, _, _, _} = Basic.load_extension(conn, "./regexp.dylib")
    :ok = Basic.disable_load_extension(conn)

    :ok =
      db
      |> Sqlite3.execute(
        "CREATE TABLE IF NOT EXISTS logs (id integer primary key, line text, timestamp text);
         CREATE INDEX logs_idx_4a224123 ON logs(timestamp DESC);
        "
      )

    {:ok, insert_stm} =
      db
      |> Sqlite3.prepare("INSERT INTO logs (id, line, timestamp) VALUES (?1, ?2, ?3)")

    Task.start(fn ->
      :stdio
      |> IO.stream(:line)
      |> Stream.filter(&(String.trim(&1) != ""))
      |> Stream.with_index(1)
      |> Stream.map(&create_log_entry/1)
      |> Stream.each(fn entry ->
        :ok = Exqlite.Sqlite3.bind(insert_stm, [entry.id, entry.line, entry.timestamp])
        :done = Exqlite.Sqlite3.step(db, insert_stm)
      end)
      |> Stream.each(&notify_subscribers/1)
      |> Stream.run()
    end)

    {:ok, %{db: db, limit: limit}}
  end

  @impl
  def handle_call({:filter, regex}, from, state = %{db: db}) do
    records =
      with {:ok, select_stm} <- prepare_query(state, regex),
           {:ok, rows} <- Sqlite3.fetch_all(db, select_stm) do
        rows
        |> Stream.map(&to_record/1)
        |> Enum.to_list()
      else
        {:error, "invalid regexp pattern"} -> []
      end

    {:reply, records, state}
  end

  def run, do: Phoenix.PubSub.subscribe(PhoenixPlayground.PubSub, @topic)

  def list_entries(regex), do: GenServer.call(__MODULE__, {:filter, regex})

  defp prepare_query(%{db: db, limit: limit}, regex) when regex == nil or regex == "" do
    with {:ok, select_stm} <-
           Sqlite3.prepare(
             db,
             "SELECT id, line, timestamp, line
              FROM logs
              ORDER BY id DESC
              LIMIT ?1"
           ),
         :ok = Exqlite.Sqlite3.bind(select_stm, [limit]) do
      {:ok, select_stm}
    end
  end

  defp prepare_query(%{db: db, limit: limit}, regex) when is_binary(regex) do
    with {:ok, select_stm} <-
           Sqlite3.prepare(
             db,
             "SELECT id, line, timestamp, regexp_replace(line, ?1, '<em>$0</em>')
              FROM logs
              WHERE regexp_like(line, ?1)
              ORDER BY id DESC
              LIMIT ?2"
           ),
         :ok = Exqlite.Sqlite3.bind(select_stm, [regex, limit]) do
      {:ok, select_stm}
    end
  end

  defp prepare_query(db, regex) do
    {:error, "invalid regexp pattern"}
  end

  defp create_log_entry({line, index}),
    do: %{id: index, line: line, timestamp: DateTime.now!("Etc/UTC"), line_decorated: line}

  defp to_record([id, line, timestamp, line_decorated]),
    do: %{id: id, line: line, timestamp: timestamp, line_decorated: {:safe, line_decorated}}

  defp notify_subscribers(line),
    do: Phoenix.PubSub.broadcast(PhoenixPlayground.PubSub, @topic, {:line, line})
end

defmodule Streamlog.State do
  use Agent

  def start_link(initial_state) do
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  def set(update_fn), do: Agent.update(__MODULE__, &update_fn.(&1))

  def get_query_and_regex do
    query = Agent.get(__MODULE__, &Map.get(&1, "query"))

    if query == nil or query == "" do
      {nil, nil}
    else
      {query, "(?i)#{query}"}
    end
  end
end

{options, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      title: :string,
      port: :integer,
      open: :boolean,
      limit: :integer
    ]
  )

options =
  Keyword.validate!(options,
    title: "Stream Log",
    port: 5051,
    open: false,
    limit: 5000
  )

Application.put_env(:streamlog, :title, Keyword.fetch!(options, :title))

Logger.info("Streamlog starting with the following options: #{inspect(options)}")

{:ok, _} =
  PhoenixPlayground.start(
    plug: Streamlog.Router,
    live_reload: false,
    child_specs: [
      {Streamlog.LogIngester, %{limit: Keyword.fetch!(options, :limit)}},
      {Streamlog.State, %{"query" => nil}}
    ],
    open_browser: Keyword.fetch!(options, :open),
    port: Keyword.fetch!(options, :port)
  )
