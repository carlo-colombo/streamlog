#! /usr/bin/env elixir

Mix.install([
  {:phoenix_playground, "~> 0.1.6"},
  {:phoenix_live_dashboard, "~> 0.8"},
  {:exqlite, "~> 0.29"},
  {:ex_sqlean_compiled, github: "carlo-colombo/ex_sqlean_compiled", submodules: true}
])

require Logger

defmodule Streamlog.IndexLive do
  use Phoenix.LiveView
  alias Streamlog.Ingester
  alias Streamlog.Forwarder
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Forwarder.subscribe()
      Process.send(self(), :refresh, [])
    end

    response =
      socket
      |> stream_logs()
      |> assign(:count, Ingester.count())
      |> assign(:sources, sources())
      |> assign(:selected_source, nil)
      |> assign(:form, to_form(%{"query" => Forwarder.get_query()}))
      |> assign(
        :page_title,
        Application.get_env(:streamlog, :title)
      )

    :net_kernel.monitor_nodes(true)

    {:ok, response}
  end

  def handle_info({:line, line}, socket) do
    {:noreply,
     stream_insert(socket, :logs, line, at: 0, limit: Application.get_env(:streamlog, :limit))}
  end

  def handle_info({:count, count}, socket) do
    {:noreply, assign(socket, :count, count)}
  end

  def handle_info({:nodeup, _node}, socket), do: refresh_sources(socket)
  def handle_info({:nodedown, _node}, socket), do: refresh_sources(socket)

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 1000)
    refresh_sources(socket)
  end

  defp refresh_sources(socket), do: {:noreply, assign(socket, :sources, sources())}

  def handle_event("filter", params = %{"query" => query}, socket) do
    Forwarder.set_query(query)

    {:noreply,
     socket
     |> stream_logs()
     |> assign(:form, to_form(params))}
  end

  def handle_event(
        "set source",
        %{"source" => source},
        socket = %{assigns: %{selected_source: selected_source}}
      ) do
    new_source = if source == selected_source, do: nil, else: source

    Forwarder.set_source(new_source)

    {:noreply,
     socket
     |> stream_logs()
     |> assign(:selected_source, new_source)}
  end

  defp stream_logs(socket) do
    stream(socket, :logs, Forwarder.list_entries(),
      reset: true,
      limit: Application.get_env(:streamlog, :limit)
    )
  end

  defp sources do
    Ingester.sources()
    |> Enum.map(
      &Map.put(
        &1,
        :connection,
        cond do
          &1.name == Node.self() |> to_name -> :self
          Enum.member?(names(), &1.name) -> :yes
          true -> :no
        end
      )
    )
    |> Enum.sort_by(
      &{Enum.find_index([:self, :yes, :no], fn e -> e == &1.connection end), &1.name}
    )
  end

  defp to_name(node),
    do:
      node
      |> Atom.to_string()
      |> String.split("@")
      |> List.first()

  defp names, do: Node.list() |> Enum.map(&to_name/1)

  attr(:field, Phoenix.HTML.FormField)
  attr(:rest, :global, include: ~w(type))

  def input(assigns) do
    ~H"""
    <input id={@field.id} name={@field.name} value={@field.value} {@rest} phx-debounce="100"/>
    """
  end

  defp icon(:self), do: "🏠"
  defp icon(:yes), do: "🌍"
  defp icon(:no), do: "❌"

  defp label(:self), do: "Local node"
  defp label(:yes), do: "Connected node"
  defp label(:no), do: "Disconnected node"

  def source(assigns) do
    ~H"""
      <span
          phx-click="set source"
          phx-value-source={@name}
          title={label(@connection)}
          class={"source #{if @selected, do: "selected"}"}
          >{icon(@connection)} {@name} ({@count})</span>
    """
  end

  def render(assigns) do
    ~H"""
    <div id="status" class="hidden" phx-disconnected={JS.show()} phx-connected={JS.hide()}>
      Attempting to reconnect...
    </div>
    <header>
        <.form for={@form} phx-change="filter" >
          <.input type="text" field={@form[:query]} placeholder="filter"/>
        </.form>
        <a href="/download"><button>Download ({ @count } log lines)</button></a>
        <div class="sources">
          Sources ({Enum.count(@sources)}):
          <%= for s <- @sources do %>
            <.source {s} selected={s.name == @selected_source}/>
          <% end %>
        </div>
    </header>
    <table>
      <thead>
        <tr>
          <th class="source">source</th>
          <th class="timestamp">timestamp</th>
          <th class="message">-</th>
        </tr>
      </thead>
      <tbody id="log-list" phx-update="stream">
        <tr :for={{id, log} <- @streams.logs} id={id} class={if rem(log.id,2)==0, do: "even", else: "odd"}  phx-hook="Decorate">
          <td class="source"><%= log.source %></td>
          <td class="timestamp"><%= log.timestamp %></td>
          <td class="message"><%= log.line_decorated %></td>
        </tr>
      </tbody>
    </table>
    <style>
      :root {
        --color-accent: #118bee15;
        --ansi-yellow: yellow;
      }
      body {
        font-family: sans-serif;
      }
      header {
        display: grid;
        justify-content: space-between;
        padding-bottom: 5px;
        row-gap: 5px;
        form {
          grid-column: 1/4;
          input {
            width: 90%;
          }
        }
        a {
          grid-column: 8;
        }

        .sources {
          grid-column: 1/8;
          grid-row: 2;

          .source {
            font-family: monospace;
            cursor: grab;
            margin-right: 3px;
            &:after {
              content: ','
            }
            &:last-child:after {
              content: ''
            }
            &.selected {
              font-weight: bold;
              background-color: lightblue;
            }
          }
        }
      }
      table {
        text-align: left;
        font-family: monospace;
        display: table;
        min-width: 100%;
        .timestamp {
          width: 250px;
        }

        .source {
          width: 100px;
        }

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
    <script type="module">
      import { FancyAnsi } from 'https://esm.run/fancy-ansi';

      const fa = new FancyAnsi();

      window.hooks.Decorate = {
        mounted() {
          const msg = this.el.querySelector('.message')
          var html = fa.toHtml(msg.innerText);
          msg.innerHTML = html
        },
        updated() {this.mounted()}
      }

    </script>
    """
  end
end

defmodule Streamlog.DownloadController do
  use Phoenix.Controller

  def download(conn, %{}) do
    conn
    |> send_download({:binary, Streamlog.Ingester.serialize()}, filename: "streamlog.db")
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

    get("/download", Streamlog.DownloadController, :download)
  end
end

defmodule Streamlog.Supervisor do
  use Supervisor
  alias Streamlog.Forwarder
  alias Exqlite.Sqlite3
  alias Exqlite.Basic

  @create_table "
    CREATE TABLE IF NOT EXISTS logs (id integer primary key, line text, timestamp text, source text);
    CREATE INDEX IF NOT EXISTS logs_idx_4a224123 ON logs(timestamp DESC);
    CREATE INDEX IF NOT EXISTS logs_idx_00742fd9 ON logs(source);
    CREATE INDEX IF NOT EXISTS logs_idx_39709ad1 ON logs(source, id DESC);
  "

  def start_link(init) do
    Supervisor.start_link(__MODULE__, init, name: __MODULE__)
  end

  @impl true
  def init(%{
        database: database,
        query: query,
        truncate: truncate,
        limit: limit,
        source: source
      }) do
    {:ok, conn = %{db: db}} = Basic.open(database)

    :ok = Basic.enable_load_extension(conn)
    {:ok, _, _, _} = Basic.load_extension(conn, ExSqleanCompiled.path_for_module("regexp"))
    :ok = Basic.disable_load_extension(conn)

    if truncate do
      :ok = Sqlite3.execute(db, "DROP TABLE IF EXISTS logs;")
    end

    :ok = Sqlite3.execute(db, @create_table)

    children = [
      {Streamlog.Ingester, %{db: db, conn: conn, source: source}},
      {Streamlog.Forwarder,
       %{
         conn: conn,
         db: db,
         query: query,
         regex: Forwarder.make_regex(query),
         limit: limit,
         source: nil
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Streamlog.Ingester do
  use GenServer
  alias Streamlog.Ingester
  alias Exqlite.Sqlite3
  alias Exqlite.Basic

  @insert "INSERT INTO logs (line, timestamp, source) VALUES (?1, ?2, ?3)"

  def start_link(init) do
    GenServer.start_link(__MODULE__, init, name: __MODULE__)
  end

  @impl true
  def init(state = %{forward_to: forward_to, source: source}) do
    remote = String.to_atom(forward_to)

    true = Node.connect(remote)

    supervisor = {Streamlog.TaskSupervisor, remote}

    consume_stdio(&Task.Supervisor.async(supervisor, Ingester, :insert, [&1, source]))
    |> Task.start()

    {:ok, state}
  end

  def init(state = %{db: db, source: source}) do
    consume_stdio(&_insert(db, &1, source))
    |> Task.start()

    {:ok, state}
  end

  defp consume_stdio(handle_line) do
    fn ->
      :stdio
      |> IO.stream(:line)
      |> Stream.filter(&(String.trim(&1) != ""))
      |> Stream.each(handle_line)
      |> Stream.run()
    end
  end

  @impl true
  def handle_call(:serialize, _from, state = %{db: db}) do
    {:ok, binary} = Sqlite3.serialize(db)
    {:reply, binary, state}
  end

  @impl true
  def handle_call(:count, _from, state = %{conn: conn}) do
    {:ok, [[count]], _} = Basic.exec(conn, "select count(*) from logs;") |> Basic.rows()
    {:reply, count, state}
  end

  @impl true
  def handle_call({:insert, line, source}, _from, state = %{db: db}) do
    {:reply, _insert(db, line, source), state}
  end

  def handle_call(:sources, _from, state = %{conn: conn}) do
    {:ok, sources, _} =
      Basic.exec(conn, "select source, count(*) from logs group by source;") |> Basic.rows()

    {:reply, sources |> Enum.map(fn [name, count] -> %{name: name, count: count} end), state}
  end

  defp _insert(db, line, source) do
    {:ok, insert_stm} = Sqlite3.prepare(db, @insert)
    :ok = Sqlite3.bind(insert_stm, [line, DateTime.now!("Etc/UTC"), source])
    :done = Sqlite3.step(db, insert_stm)
  end

  def serialize, do: GenServer.call(__MODULE__, :serialize)
  def count, do: GenServer.call(__MODULE__, :count)
  def insert(line, source), do: GenServer.call(__MODULE__, {:insert, line, source})
  def sources, do: GenServer.call(__MODULE__, :sources)
end

defmodule Streamlog.Forwarder do
  use GenServer

  alias Exqlite.Sqlite3
  alias Exqlite.Basic
  alias Streamlog.Ingester

  @topic inspect(__MODULE__)
  @highlight IO.ANSI.yellow_background() <> "$0" <> IO.ANSI.reset()

  def start_link(init) do
    GenServer.start_link(__MODULE__, init, name: __MODULE__)
  end

  @impl true
  def init(init_arg = %{db: db}) do
    :ok = Sqlite3.set_update_hook(db, self())

    {:ok, init_arg}
  end

  @impl true
  def handle_cast({:set_query, query}, state),
    do: {:noreply, %{state | regex: make_regex(query), query: query}}

  @impl true
  def handle_cast({:set_source, source}, state),
    do: {:noreply, %{state | source: source}}

  @impl true
  def handle_call(:get_query, _from, state = %{query: query}), do: {:reply, query, state}

  @impl true
  def handle_call(:list, _from, state = %{db: db}) do
    records =
      with {:ok, select_stm} <- prepare_query(state),
           {:ok, rows} <- Sqlite3.fetch_all(db, select_stm) do
        rows
        |> Stream.map(&to_record/1)
        |> Enum.to_list()
      else
        {:error, message} ->
          Logger.error(inspect(message))
          []
      end

    {:reply, records, state}
  end

  def set_source(source), do: GenServer.cast(__MODULE__, {:set_source, source})
  def set_query(query), do: GenServer.cast(__MODULE__, {:set_query, query})
  def get_query, do: GenServer.call(__MODULE__, :get_query)
  def list_entries, do: GenServer.call(__MODULE__, :list)

  def make_regex(""), do: nil
  def make_regex(query), do: "(?i)" <> query

  @impl true
  def handle_info({:insert, _, _, id}, state = %{db: db}) do
    Task.start(fn -> notify_subscribers(:count, Ingester.count()) end)

    with {:ok, select_stm} <- prepare_query(state, id),
         result <- Sqlite3.step(db, select_stm) do
      case result do
        {:row, row} ->
          row
          |> to_record()
          |> then(&notify_subscribers(:line, &1))

        :done ->
          nil
      end
    else
      {:error, message} ->
        Logger.error(inspect(message))
        []
    end

    {:noreply, state}
  end

  def notify_subscribers(event, data),
    do: Phoenix.PubSub.broadcast(PhoenixPlayground.PubSub, @topic, {event, data})

  def subscribe, do: Phoenix.PubSub.subscribe(PhoenixPlayground.PubSub, @topic)

  defp to_record([id, line, timestamp, line_decorated, source]),
    do: %{
      id: id,
      line: line,
      timestamp: timestamp,
      line_decorated: line_decorated,
      source: source
    }

  defp prepare_query(%{db: db, source: source, limit: limit, regex: regex}, id \\ nil) do
    query = """
    SELECT
      id,
      line,
      timestamp,
      #{if regex, do: "regexp_replace(line, ?, ?)", else: "line"} as line,
      source
    FROM logs
    WHERE 1=1
    """

    params = []

    {query, params} =
      if regex do
        query = query <> " AND regexp_like(line, ?)"
        params = params ++ [regex, @highlight, regex]
        {query, params}
      else
        {query, params}
      end

    {query, params} =
      if source,
        do: {query <> " AND source = ?", params ++ [source]},
        else: {query, params}

    {query, params} =
      if id,
        do: {query <> " AND id = ?", params ++ [id]},
        else: {query, params}

    query = query <> " ORDER BY id DESC LIMIT ?"
    params = params ++ [limit]

    {:ok, select_stm} = Sqlite3.prepare(db, query)
    :ok = Sqlite3.bind(select_stm, params)
    {:ok, select_stm}
  end
end

{options, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      title: :string,
      port: :integer,
      open: :boolean,
      limit: :integer,
      query: :string,
      database: :string,
      truncate: :boolean,
      name: :string,
      forward_to: :string
    ]
  )

options =
  options
  |> Keyword.validate!(
    title: "Stream Log",
    port: 5051,
    open: false,
    limit: 500,
    query: "",
    truncate: false,
    database: ":memory:",
    name: "streamlog@localhost",
    forward_to: nil
  )
  |> Enum.into(%{})

Application.put_env(:streamlog, :title, options.title)
Application.put_env(:streamlog, :limit, options.limit)

Logger.info("Streamlog starting with the following options: #{inspect(options)}")
Logger.info("Connect to this node using '#{options.name}'")

{:ok, _} =
  options.name
  |> String.to_atom()
  |> Node.start(:shortnames)

[source, _] =
  Node.self()
  |> Atom.to_string()
  |> String.split("@")

options = Map.merge(options, %{source: source})

if options.forward_to do
  {:ok, _} =
    Supervisor.start_link(
      [
        {Streamlog.Ingester, options}
      ],
      strategy: :one_for_one
    )

  Process.sleep(:infinity)
else
  {:ok, _} =
    PhoenixPlayground.start(
      plug: Streamlog.Router,
      live_reload: false,
      child_specs: [
        {Streamlog.Supervisor, options},
        {Task.Supervisor, name: Streamlog.TaskSupervisor}
      ],
      open_browser: options.open,
      port: options.port
    )
end
