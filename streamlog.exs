Mix.install([
  {:phoenix_playground, "~> 0.1.6"},
  {:phoenix_live_dashboard, "~> 0.8"}
])

defmodule Streamlog.IndexLive do
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Streamlog.Worker.run()
    end

    {query, regex} = Streamlog.State.get_query_and_regex()

    response =
      socket
      |> stream(:logs, filtered_lines(regex))
      |> assign(:form, to_form(%{"query" => query}))
      |> assign(
        :page_title,
        Application.get_env(:streamlog, Streamlog.Endpoint) |> Keyword.get(:title)
      )

    {:ok, response}
  end

  def handle_info({:line, line}, socket) do
    {_, regex} = Streamlog.State.get_query_and_regex()

    {:noreply,
     if regex == nil or String.match?(line.line, regex) do
       stream_insert(socket, :logs, line, at: 0)
     else
       socket
     end}
  end

  def handle_event("filter", %{"query" => query} = params, socket) do
    Streamlog.State.set(&%{&1 | "query" => query})

    {_, regex} = Streamlog.State.get_query_and_regex()

    {:noreply,
     socket
     |> stream(:logs, filtered_lines(regex), reset: true)
     |> assign(:form, to_form(params))}
  end

  defp filtered_lines(regex) do
    :ets.tab2list(:logs)
    |> Enum.map(&elem(&1, 1))
    |> then(fn lines ->
      if regex == nil do
        lines
      else
        lines
        |> Enum.filter(&String.match?(&1.line, regex))
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
    <h1>Logs</h1>
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
          <td class="message"><%= log.line %></td>
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

  def start_link([]) do
    :ets.new(:logs, [:set, :public, :named_table])
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    {:ok, false}
  end

  def run() do
    GenServer.cast(__MODULE__, :run)
    Phoenix.PubSub.subscribe(PhoenixPlayground.PubSub, @topic)
  end

  @impl true
  def handle_cast(:run, false) do
    :stdio
    |> IO.stream(:line)
    |> Stream.with_index(1)
    |> Stream.map(fn {line, index} ->
      %{id: index, line: line, timestamp: DateTime.now!("Etc/UTC")}
    end)
    |> Stream.each(&:ets.insert(:logs, {&1.id, &1}))
    |> Stream.each(&notify_subscribers(&1))
    |> Stream.run()

    {:noreply, :running}
  end

  def handle_cast(:run, :running), do: {:noreply, :running}

  defp notify_subscribers(line) do
    Phoenix.PubSub.broadcast(PhoenixPlayground.PubSub, @topic, {:line, line})
  end
end

defmodule Streamlog.State do
  use Agent

  def start_link(initial_state) do
    Agent.start_link(fn -> initial_state end, name: __MODULE__)
  end

  def value do
    Agent.get(__MODULE__, & &1)
  end

  def set(update_fn) do
    Agent.update(__MODULE__, &update_fn.(&1))
  end

  def get(key), do: Agent.get(__MODULE__, &Map.get(&1, key))

  def get_query_and_regex do
    query = get("query")

    if query == nil do
      {nil, nil}
    else
      case Regex.compile(query) do
        {:ok, regex} -> {query, regex}
        _ -> {query, nil}
      end
    end
  end
end

{options, _, _} = OptionParser.parse(System.argv(), strict: [title: :string, port: :integer])

Application.put_env(:streamlog, Streamlog.Endpoint,
  title: Keyword.get(options, :title, "Stream Log")
)

{:ok, _} =
  PhoenixPlayground.start(
    plug: Streamlog.Router,
    child_specs: [
      Streamlog.Worker,
      {Streamlog.State, %{"query" => nil}}
    ],
    open_browser: false,
    port: Keyword.get(options, :port, 5001)
  )
