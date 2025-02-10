#! /usr/bin/env elixir

Mix.install([
  {:phoenix_playground, "~> 0.1.6"},
  {:phoenix_live_dashboard, "~> 0.8"},
  {:exqlite, "~> 0.27"},
  {:ex_sqlean_compiled, github: "carlo-colombo/ex_sqlean_compiled", submodules: true}
])

require Logger

defmodule MyAnsi do
  @ansi_regex ~r/(\x9B|\x1B\[)[0-?]*[ -\/]*[@-~]/
  @non_alpha_regex ~r/[^0-9a-zA-Z]/

  def strip_ansi(ansi_string) when is_binary(ansi_string) do
    Regex.replace(@ansi_regex, ansi_string, "")
    |> String.split(",")
    |> Enum.map(&Regex.replace(@non_alpha_regex, &1, ""))
  end
end

defmodule Streamlog.IndexLive do
  use Phoenix.LiveView
  alias Streamlog.State
  alias Streamlog.LogIngester
  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket) do
    if connected?(socket), do: LogIngester.run()

    {query, _} = State.get_query_and_regex()

    response =
      socket
      |> stream(:logs, filtered_lines())
      |> assign(:count, 0)
      |> assign(:form, to_form(%{"query" => query}))
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
    State.set(&%{&1 | "query" => query})

    {:noreply,
     socket
     |> stream(:logs, filtered_lines(), reset: true)
     |> assign(:form, to_form(params))}
  end

  defp filtered_lines() do
    {_, compiled_regex} = State.get_query_and_regex()

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
        form {
          grid-column: 1;
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
    |> send_download({:binary, Streamlog.LogIngester.serialize()}, filename: "streamlog.db")
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

defmodule Streamlog.LogIngester do
  use GenServer
  alias Exqlite.Sqlite3
  alias Exqlite.Basic
  alias Streamlog.State

  @topic inspect(__MODULE__)

  def start_link(init) do
    GenServer.start_link(__MODULE__, init, name: __MODULE__)
  end

  @impl true
  def init(%{limit: limit}) do
    {:ok, conn = %{db: db}} = Basic.open(":memory:")

    :ok = Basic.enable_load_extension(conn)
    {:ok, _, _, _} = Basic.load_extension(conn, ExSqleanCompiled.path_for_module("regexp"))
    :ok = Basic.disable_load_extension(conn)

    :ok =
      db
      |> Sqlite3.execute(
        "CREATE TABLE IF NOT EXISTS logs (id integer primary key, line text, timestamp text);
         CREATE INDEX logs_idx_4a224123 ON logs(timestamp DESC);
        "
      )

    Sqlite3.set_update_hook(db, self())

    Task.start(fn ->
      {:ok, insert_stm} =
        db
        |> Sqlite3.prepare("INSERT INTO logs (id, line, timestamp) VALUES (?1, ?2, ?3)")

      :stdio
      |> IO.stream(:line)
      |> Stream.filter(&(String.trim(&1) != ""))
      |> Stream.with_index(1)
      |> Stream.map(&create_log_entry/1)
      |> Stream.each(fn entry ->
        :ok = Exqlite.Sqlite3.bind(insert_stm, [entry.id, entry.line, entry.timestamp])
        :done = Exqlite.Sqlite3.step(db, insert_stm)
      end)
      |> Stream.run()
    end)

    {:ok, %{db: db, limit: limit, conn: conn, query: ""}}
  end

  @impl true
  def handle_call({:filter, regex}, _from, state = %{db: db}) do
    records =
      with {:ok, select_stm} <- prepare_query(state, regex || ""),
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

  @impl true
  def handle_call(:serialize, _from, state = %{db: db}) do
    {:ok, binary} = Sqlite3.serialize(db)
    {:reply, binary, state}
  end

  defp update_count(conn) do
    {:ok, [[count]], _} = Basic.exec(conn, "select count(*) from logs;") |> Basic.rows()
    notify_subscribers(:count, count)
  end

  @impl true
  def handle_info({:insert, _, _, id}, state = %{db: db, conn: conn}) do
    Task.start(fn -> update_count(conn) end)

    {_, regex} = State.get_query_and_regex()

    with {:ok, select_stm} <- prepare_query(state, regex || "", [id]),
         result <- Sqlite3.step(db, select_stm) do
      case result do
        {:row, row} -> row |> to_record() |> notify_subscribers()
        :done -> nil
      end
    else
      {:error, message} ->
        Logger.error(inspect(message))
        []
    end

    {:noreply, state}
  end

  def run, do: Phoenix.PubSub.subscribe(PhoenixPlayground.PubSub, @topic)

  def notify_subscribers(event, data),
    do: Phoenix.PubSub.broadcast(PhoenixPlayground.PubSub, @topic, {event, data})

  def list_entries(regex), do: GenServer.call(__MODULE__, {:filter, regex})

  def serialize(), do: GenServer.call(__MODULE__, :serialize)

  defp highlight(t), do: IO.ANSI.yellow_background() <> t <> IO.ANSI.reset()

  defp prepare_select(""), do: {"line", "?1=?1"}

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

  defp create_log_entry({line, index}),
    do: %{id: index, line: line, timestamp: DateTime.now!("Etc/UTC"), line_decorated: line}

  defp to_record([id, line, timestamp, line_decorated]),
    do: %{id: id, line: line, timestamp: timestamp, line_decorated: line_decorated}

  defp notify_subscribers(line), do: notify_subscribers(:line, line)
end

defmodule Streamlog.State do
  use Agent

  def start_link(initial_state) do
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  def set(update_fn), do: Agent.update(__MODULE__, &update_fn.(&1))

  def get_query_and_regex do
    if query = Agent.get(__MODULE__, &Map.get(&1, "query", "")) do
      {query, "(?i)#{query}"}
    else
      {nil, nil}
    end
  end
end

{options, _, _} =
  OptionParser.parse(System.argv(),
    strict: [
      title: :string,
      port: :integer,
      open: :boolean,
      limit: :integer,
      query: :string
    ]
  )

options =
  Keyword.validate!(options,
    title: "Stream Log",
    port: 5051,
    open: false,
    limit: 5000,
    query: nil
  )

Application.put_env(:streamlog, :title, Keyword.fetch!(options, :title))

Logger.info("Streamlog starting with the following options: #{inspect(options)}")

{:ok, _} =
  PhoenixPlayground.start(
    plug: Streamlog.Router,
    live_reload: false,
    child_specs: [
      {Streamlog.LogIngester, %{limit: Keyword.fetch!(options, :limit)}},
      {Streamlog.State, %{"query" => Keyword.fetch!(options, :query)}},
    ],
    open_browser: Keyword.fetch!(options, :open),
    port: Keyword.fetch!(options, :port)
  )
