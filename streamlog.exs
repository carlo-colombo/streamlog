#! /usr/bin/env elixir

Mix.install([
  {:phoenix_playground, "~> 0.1.6"},
  {:phoenix_live_dashboard, "~> 0.8"},
  {:exqlite, "~> 0.27"},
  {:ex_sqlean_compiled, github: "carlo-colombo/ex_sqlean_compiled", submodules: true}
])

require Logger

defmodule Streamlog.IndexLive do
  use Phoenix.LiveView
  alias Streamlog.Forwarder
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    if connected?(socket), do: Forwarder.run()

    response =
      socket
      |> stream(:logs, filtered_lines())
      |> assign(:count, Forwarder.count())
      |> assign(:form, to_form(%{"query" => Forwarder.get_query()}))
      |> assign(
        :page_title,
        Application.get_env(:streamlog, :title)
      )

    {:ok, response}
  end

  def handle_info({:line, line}, socket) do
    {:noreply, stream_insert(socket, :logs, line, at: 0)}
  end

  def handle_info({:count, count}, socket) do
    {:noreply, assign(socket, :count, count)}
  end

  def handle_event("filter", %{"query" => query} = params, socket) do
    Forwarder.set_query(query)

    {:noreply,
     socket
     |> stream(:logs, filtered_lines(), reset: true)
     |> assign(:form, to_form(params))}
  end

  defp filtered_lines(), do: Forwarder.list_entries()

  attr(:field, Phoenix.HTML.FormField)
  attr(:rest, :global, include: ~w(type))

  def input(assigns) do
    ~H"""
    <input id={@field.id} name={@field.name} value={@field.value} {@rest} />
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
    </header>
    <table>
      <thead>
        <tr>
          <th>timestamp</th>
          <th>-</th>
        </tr>
      </thead>
      <tbody id="log-list" phx-update="stream">
        <tr :for={{id, log} <- @streams.logs} id={id} class={if rem(log.id,2)==0, do: "even", else: "odd"}  phx-hook="Decorate">
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
      header {
        display: grid;
        justify-content: space-between;
        padding-bottom: 5px;
        form { grid-column: 1;
          input {
            width: 90%;
          }
        }
        a {
          grid-column: 8;
        }
      }
      table {
        text-align: left;
        font-family: monospace;
        display: table;
        min-width: 100%;

        td {
          padding-right: 10px;
          border-right: solid 1px #339981;

          &.timestamp {
            min-width: 250px;
          }

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

  @create_table "CREATE TABLE IF NOT EXISTS logs (id integer primary key, line text, timestamp text);
         CREATE INDEX IF NOT EXISTS logs_idx_4a224123 ON logs(timestamp DESC);
        "

  def start_link(init) do
    Supervisor.start_link(__MODULE__, init, name: __MODULE__)
  end

  @impl true
  def init(options) do
    {:ok, conn = %{db: db}} = Basic.open(Keyword.fetch!(options, :database))

    :ok = Basic.enable_load_extension(conn)
    {:ok, _, _, _} = Basic.load_extension(conn, ExSqleanCompiled.path_for_module("regexp"))
    :ok = Basic.disable_load_extension(conn)

    if Keyword.fetch!(options, :truncate) do
      :ok = Sqlite3.execute(db, "DROP TABLE IF EXISTS logs;")
    end
    :ok = Sqlite3.execute(db, @create_table)

    query = Keyword.fetch!(options, :query)

    children = [
      {Streamlog.Ingester, %{db: db}},
      {Streamlog.Forwarder,
       %{
         conn: conn,
         db: db,
         query: query,
         regex: Forwarder.make_regex(query),
         limit: Keyword.fetch!(options, :limit)
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Streamlog.Ingester do
  use GenServer
  alias Exqlite.Sqlite3
  alias Exqlite.Basic

  @insert "INSERT INTO logs (line, timestamp) VALUES (?1, ?2)"

  def start_link(init) do
    GenServer.start_link(__MODULE__, init, name: __MODULE__)
  end

  @impl true
  def init(state = %{db: db}) do
    Task.start(fn ->
      {:ok, insert_stm} = Sqlite3.prepare(db, @insert)

      :stdio
      |> IO.stream(:line)
      |> Stream.filter(&(String.trim(&1) != ""))
      |> Stream.each(fn line ->
        :ok = Exqlite.Sqlite3.bind(insert_stm, [line, DateTime.now!("Etc/UTC")])
        :done = Exqlite.Sqlite3.step(db, insert_stm)
      end)
      |> Stream.run()
    end)

    {:ok, state}
  end

  @impl true
  def handle_call(:serialize, _from, state = %{db: db}) do
    {:ok, binary} = Sqlite3.serialize(db)
    {:reply, binary, state}
  end

  def serialize(), do: GenServer.call(__MODULE__, :serialize)
end

defmodule Streamlog.Forwarder do
  use GenServer

  alias Exqlite.Sqlite3
  alias Exqlite.Basic

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
  def handle_call(:get_query, _from, state = %{query: query}), do: {:reply, query, state}

  @impl true
  def handle_call(:count, _from, state = %{conn: conn}) do
    {:ok, [[count]], _} = Basic.exec(conn, "select count(*) from logs;") |> Basic.rows()
    {:reply, count, state}
  end

  @impl true
  def handle_call(:list, _from, state = %{db: db, regex: regex}) do
    records =
      with {:ok, select_stm} <- prepare_query(state, regex),
           {:ok, rows} <- Sqlite3.fetch_all(db, select_stm) do
        rows
        |> Stream.map(&to_record/1)
        |> Enum.to_list()
      else
        {:error, message} ->
          IO.inspect(message)
          []
      end

    {:reply, records, state}
  end

  def count(), do: GenServer.call(__MODULE__, :count)
  def set_query(query), do: GenServer.cast(__MODULE__, {:set_query, query})
  def get_query(), do: GenServer.call(__MODULE__, :get_query)
  def list_entries(), do: GenServer.call(__MODULE__, :list)

  def make_regex(""), do: nil
  def make_regex(query), do: "(?i)" <> query

  @impl true
  def handle_info({:insert, _, _, id}, state = %{db: db, regex: regex}) do
    Task.start(fn -> notify_subscribers(:count, count()) end)

    with {:ok, select_stm} <- prepare_query(state, regex, [id]),
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

  def run, do: Phoenix.PubSub.subscribe(PhoenixPlayground.PubSub, @topic)

  defp to_record([id, line, timestamp, line_decorated]),
    do: %{id: id, line: line, timestamp: timestamp, line_decorated: line_decorated}

  defp highlight(t), do: IO.ANSI.yellow_background() <> t <> IO.ANSI.reset()

  defp prepare_select(nil), do: {"line", "(?1=?1 or 1=1)"}

  defp prepare_select(_regex),
    do: {"regexp_replace(line, ?1, '#{highlight("$0")}')", "regexp_like(line, ?1)"}

  defp prepare_query(%{db: db, limit: limit}, regex) do
    with {field, filter} <- prepare_select(regex),
         {:ok, select_stm} <-
           Sqlite3.prepare(
             db,
             "SELECT id, line, timestamp, #{field}
              FROM logs
              WHERE #{filter}
              ORDER BY id DESC
              LIMIT ?2"
           ),
         :ok = Exqlite.Sqlite3.bind(select_stm, [regex, limit]) do
      {:ok, select_stm}
    end
  end

  defp prepare_query(%{db: db}, regex, ids) do
    with {field, filter} <- prepare_select(regex),
         {:ok, select_stm} <-
           Sqlite3.prepare(
             db,
             "SELECT id, line, timestamp, #{field}
              FROM logs
              WHERE #{filter} AND id in (#{ids |> Enum.map(fn _ -> "?" end) |> Enum.join(",")})
              ORDER BY id DESC"
           ),
         :ok = Exqlite.Sqlite3.bind(select_stm, [regex | ids]) do
      {:ok, select_stm}
    end
  end

  defp prepare_query(_db, _regex, _ids), do: {:error, nil}
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
      truncate: :boolean
    ]
  )

options =
  Keyword.validate!(options,
    title: "Stream Log",
    port: 5051,
    open: false,
    limit: 5000,
    query: "",
    database: ":memory:",
    truncate: false
  )

Application.put_env(:streamlog, :title, Keyword.fetch!(options, :title))

Logger.info("Streamlog starting with the following options: #{inspect(options)}")

{:ok, _} =
  PhoenixPlayground.start(
    plug: Streamlog.Router,
    live_reload: false,
    child_specs: [
      {Streamlog.Supervisor, options}
    ],
    open_browser: Keyword.fetch!(options, :open),
    port: Keyword.fetch!(options, :port)
  )
