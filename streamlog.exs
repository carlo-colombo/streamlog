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
    if connected?(socket), do: Forwarder.subscribe()

    response =
      socket
      |> stream(:logs, filtered_lines())
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
    {:noreply, stream_insert(socket, :logs, line, at: 0)}
  end

  def handle_info({:count, count}, socket) do
    {:noreply, assign(socket, :count, count)}
  end

  def handle_info({:nodeup, _node}, socket) do
    {:noreply, assign(socket, :sources, sources())}
  end

  def handle_info({:nodedown, _node}, socket) do
    {:noreply, assign(socket, :sources, sources())}
  end

  def handle_event("filter", params = %{"query" => query}, socket) do
    Forwarder.set_query(query)

    {:noreply,
     socket
     |> stream(:logs, filtered_lines(), reset: true)
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
     |> stream(:logs, filtered_lines(), reset: true)
     |> assign(:selected_source, new_source)}
  end

  defp filtered_lines, do: Forwarder.list_entries()

  defp sources,
    do:
      [Node.self() | Node.list()]
      |> Enum.map(fn n -> n |> Atom.to_string() |> String.split("@") |> List.first() end)

  attr(:field, Phoenix.HTML.FormField)
  attr(:rest, :global, include: ~w(type))

  def input(assigns) do
    ~H"""
    <input id={@field.id} name={@field.name} value={@field.value} {@rest} phx-debounce="100"/>
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
          Connected sources ({Enum.count(@sources)}):
            <span :for={ s <- @sources} phx-click="set source" phx-value-source={s} class={"source #{if s == @selected_source, do: "selected"}"}><%= s %></span>
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
            &:after {
              content: ', '
            }
            &:last-child:after {
              content: ''
            }
            &.selected {
              font-weight: bold;
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

  defp _insert(db, line, source) do
    {:ok, insert_stm} = Sqlite3.prepare(db, @insert)
    :ok = Sqlite3.bind(insert_stm, [line, DateTime.now!("Etc/UTC"), source])
    :done = Sqlite3.step(db, insert_stm)
  end

  def serialize, do: GenServer.call(__MODULE__, :serialize)
  def count, do: GenServer.call(__MODULE__, :count)
  def insert(line, source), do: GenServer.call(__MODULE__, {:insert, line, source})
end

defmodule Streamlog.Forwarder do
  use GenServer

  alias Exqlite.Sqlite3
  alias Exqlite.Basic
  alias Streamlog.Ingester

  @topic inspect(__MODULE__)

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

  defp highlight(t), do: IO.ANSI.yellow_background() <> t <> IO.ANSI.reset()

  defp and_cond(false, _), do: ""
  defp and_cond(nil, _), do: ""
  defp and_cond(_, do: query_part), do: "AND " <> query_part

  defp prepare_query(%{db: db, source: source, limit: limit, regex: regex},  id \\ nil) do
    {:ok, select_stm} =
      Sqlite3.prepare(
        db,
        "SELECT
          id,
          line,
          timestamp,
          #{if regex, do: "regexp_replace(line, '#{regex}', '#{highlight("$0")}')", else: "line"} as line,
          source
        FROM logs
        WHERE 1=1
          #{and_cond(regex, do: "regexp_like(line, '#{regex}')")}
          #{and_cond(source, do: "source = '#{source}'")}
          #{and_cond(id, do: "id = #{id}")}
        ORDER BY id DESC
        LIMIT #{limit}"
      )

    :ok = Exqlite.Sqlite3.bind(select_stm, [])
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
    limit: 5000,
    query: "",
    truncate: false,
    database: ":memory:",
    name: "streamlog@localhost",
    forward_to: nil
  )
  |> Enum.into(%{})

Application.put_env(:streamlog, :title, options.title)

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
