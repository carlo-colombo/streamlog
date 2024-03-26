Application.put_env(:streamlog, Streamlog.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 5001],
  server: true,
  live_view: [signing_salt: "aaaaaaaa"],
  secret_key_base: String.duplicate("a", 64)
)

Mix.install([
  {:plug_cowboy, "~> 2.5"},
  {:jason, "~> 1.0"},
  {:phoenix, "~> 1.7.11", override: true},
  {:phoenix_live_view, "~> 0.20.12"},
  {:phoenix_live_dashboard, "~> 0.8.3"}
])

defmodule Streamlog.ErrorView do
  def render(template, _), do: Phoenix.Controller.status_message_from_template(template)
end

defmodule Streamlog.IndexLive do
  use Phoenix.LiveView, layout: {__MODULE__, :live}

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Streamlog.Worker.run()
    end

    lines =
      :logs
      |> :ets.tab2list()
      |> Enum.sort(:desc)
      |> Enum.map(&elem(&1, 1))

    {:ok,
     socket
     |> stream(:logs, lines)
     |> assign(:form, to_form(%{"query" => nil}))}
  end

  def handle_info({:line, line}, socket) do
    {:noreply,
     socket
     |> stream_insert(:logs, line, at: 0)}
  end

  def render("live.html", assigns) do
    ~H"""
    <script src="https://cdn.jsdelivr.net/npm/phoenix@1.7.11/priv/static/phoenix.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/phoenix_live_view@0.20.12/priv/static/phoenix_live_view.min.js"></script>
    <link rel="stylesheet" href="https://unpkg.com/mvp.css">
    <script>
      let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket)
      liveSocket.connect()
    </script>
    <style>
      table td {
        text-align: left;
      }
    </style>
    <%= @inner_content %>
    """
  end

  attr :field, Phoenix.HTML.FormField
  attr :rest, :global, include: ~w(type)
  def input(assigns) do
    ~H"""
    <input id={@field.id} name={@field.name} value={@field.value} {@rest} />
    """
  end

  def handle_event("filter", %{"query" => query} = params, socket) do
    {:noreply, assign(socket, form: to_form(params))}
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
        <tr :for={{id, log} <- @streams.logs} id={id} >
          <td><%= log.timestamp %></td>
          <td><%= log.line %></td>
        </tr>
      </tbody>
    </table>
    """
  end
end

defmodule Streamlog.Router do
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug(:accepts, ["html"])
  end

  scope "/", Streamlog do
    pipe_through(:browser)

    live("/", IndexLive, :index)
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

  def init([]) do
    {:ok, false}
  end

  def run() do
    GenServer.cast(__MODULE__, :run)
    Phoenix.PubSub.subscribe(:lines, @topic)
  end

  @impl true
  def handle_cast(:run, false) do
    :stdio
    |> IO.stream(:line)
    |> Stream.with_index(1)
    |> Stream.map(fn {line, index} ->
      %{id: index, line: line, timestamp: DateTime.now!("Etc/UTC")}
    end)
    |> Stream.each(&notify_subscribers(&1))
    |> Stream.each(&:ets.insert(:logs, {&1.id, &1}))
    |> Stream.run()

    {:noreply, :running}
  end

  def handle_cast(:run, :running), do: {:noreply, :running}

  defp notify_subscribers(line) do
    Phoenix.PubSub.broadcast(:lines, @topic, {:line, line})
  end
end

defmodule Streamlog.Endpoint do
  use Phoenix.Endpoint, otp_app: :streamlog
  socket("/live", Phoenix.LiveView.Socket)
  plug(Streamlog.Router)
end

{:ok, _} =
  Supervisor.start_link(
    [
      Streamlog.Endpoint,
      Streamlog.Worker,
      {Phoenix.PubSub, name: :lines}
    ],
    strategy: :one_for_one
  )

unless IEx.started?() do
  Process.sleep(:infinity)
end
