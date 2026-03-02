defmodule WSocketIO do
  @moduledoc """
  wSocket Elixir SDK — Realtime Pub/Sub client with Presence, History, and Push.

  ## Usage

      {:ok, client} = WSocketIO.Client.start_link("ws://localhost:9001", "your-api-key")
      channel = WSocketIO.Client.channel(client, "chat")
      WSocketIO.Channel.subscribe(channel, fn data, meta -> IO.inspect(data) end)
      WSocketIO.Channel.publish(channel, %{text: "hello"})
  """
end

# ─── Types ──────────────────────────────────────────────────

defmodule WSocketIO.MessageMeta do
  @moduledoc false
  defstruct [:id, :channel, :timestamp]
end

defmodule WSocketIO.PresenceMember do
  @moduledoc false
  defstruct [:client_id, :data, joined_at: 0]
end

defmodule WSocketIO.HistoryMessage do
  @moduledoc false
  defstruct [:id, :channel, :data, :publisher_id, :timestamp, sequence: 0]
end

defmodule WSocketIO.HistoryResult do
  @moduledoc false
  defstruct [:channel, messages: [], has_more: false]
end

# ─── Channel (GenServer) ────────────────────────────────────

defmodule WSocketIO.Channel do
  @moduledoc "Represents a pub/sub channel."
  use GenServer

  defstruct [:name, :send_fn, message_cbs: [], history_cbs: [], presence_state: %{}]

  def start_link(name, send_fn) do
    GenServer.start_link(__MODULE__, %__MODULE__{name: name, send_fn: send_fn})
  end

  def subscribe(pid, callback \\ nil) do
    GenServer.call(pid, {:subscribe, callback})
  end

  def unsubscribe(pid) do
    GenServer.call(pid, :unsubscribe)
  end

  def publish(pid, data, opts \\ []) do
    GenServer.call(pid, {:publish, data, opts})
  end

  def history(pid, opts \\ []) do
    GenServer.call(pid, {:history, opts})
  end

  def on_history(pid, callback) do
    GenServer.call(pid, {:on_history, callback})
  end

  # Presence delegations
  def presence_enter(pid, opts \\ []), do: GenServer.call(pid, {:presence, :enter, opts})
  def presence_leave(pid), do: GenServer.call(pid, {:presence, :leave, []})
  def presence_update(pid, data), do: GenServer.call(pid, {:presence, :update, data})
  def presence_get(pid), do: GenServer.call(pid, {:presence, :get, []})
  def on_presence_enter(pid, cb), do: GenServer.call(pid, {:presence_cb, :enter, cb})
  def on_presence_leave(pid, cb), do: GenServer.call(pid, {:presence_cb, :leave, cb})
  def on_presence_update(pid, cb), do: GenServer.call(pid, {:presence_cb, :update, cb})
  def on_presence_members(pid, cb), do: GenServer.call(pid, {:presence_cb, :members, cb})

  # Internal
  def handle_message(pid, data, meta), do: GenServer.cast(pid, {:message, data, meta})
  def handle_history_result(pid, result), do: GenServer.cast(pid, {:history_result, result})
  def handle_presence_event(pid, action, data), do: GenServer.cast(pid, {:presence_event, action, data})

  # ── Callbacks ──

  @impl true
  def init(state), do: {:ok, Map.put(state, :presence_cbs, %{enter: [], leave: [], update: [], members: []})}

  @impl true
  def handle_call({:subscribe, callback}, _from, state) do
    state.send_fn.(%{"action" => "subscribe", "channel" => state.name})
    new_cbs = if callback, do: state.message_cbs ++ [callback], else: state.message_cbs
    {:reply, :ok, %{state | message_cbs: new_cbs}}
  end

  def handle_call(:unsubscribe, _from, state) do
    state.send_fn.(%{"action" => "unsubscribe", "channel" => state.name})
    {:reply, :ok, %{state | message_cbs: []}}
  end

  def handle_call({:publish, data, opts}, _from, state) do
    msg = %{
      "action" => "publish",
      "channel" => state.name,
      "data" => data,
      "id" => UUID.uuid4()
    }
    msg = if Keyword.get(opts, :persist) != nil, do: Map.put(msg, "persist", Keyword.get(opts, :persist)), else: msg
    state.send_fn.(msg)
    {:reply, :ok, state}
  end

  def handle_call({:history, opts}, _from, state) do
    msg = %{"action" => "history", "channel" => state.name}
    msg = Enum.reduce(opts, msg, fn {k, v}, acc -> Map.put(acc, to_string(k), v) end)
    state.send_fn.(msg)
    {:reply, :ok, state}
  end

  def handle_call({:on_history, callback}, _from, state) do
    {:reply, :ok, %{state | history_cbs: state.history_cbs ++ [callback]}}
  end

  def handle_call({:presence, :enter, opts}, _from, state) do
    data = Keyword.get(opts, :data)
    state.send_fn.(%{"action" => "presence.enter", "channel" => state.name, "data" => data})
    {:reply, :ok, state}
  end

  def handle_call({:presence, :leave, _}, _from, state) do
    state.send_fn.(%{"action" => "presence.leave", "channel" => state.name})
    {:reply, :ok, state}
  end

  def handle_call({:presence, :update, data}, _from, state) do
    state.send_fn.(%{"action" => "presence.update", "channel" => state.name, "data" => data})
    {:reply, :ok, state}
  end

  def handle_call({:presence, :get, _}, _from, state) do
    state.send_fn.(%{"action" => "presence.get", "channel" => state.name})
    {:reply, :ok, state}
  end

  def handle_call({:presence_cb, type, cb}, _from, state) do
    cbs = Map.update!(state.presence_cbs, type, &(&1 ++ [cb]))
    {:reply, :ok, %{state | presence_cbs: cbs}}
  end

  @impl true
  def handle_cast({:message, data, meta}, state) do
    Enum.each(state.message_cbs, fn cb -> cb.(data, meta) end)
    {:noreply, state}
  end

  def handle_cast({:history_result, result}, state) do
    Enum.each(state.history_cbs, fn cb -> cb.(result) end)
    {:noreply, state}
  end

  def handle_cast({:presence_event, action, data}, state) do
    type = case action do
      "presence.enter" -> :enter
      "presence.leave" -> :leave
      "presence.update" -> :update
      "presence.members" -> :members
      _ -> nil
    end

    if type do
      cbs = Map.get(state.presence_cbs, type, [])
      case type do
        :members ->
          members = (data["members"] || [])
            |> Enum.map(&parse_member/1)
          Enum.each(cbs, fn cb -> cb.(members) end)
        _ ->
          member = parse_member(data)
          Enum.each(cbs, fn cb -> cb.(member) end)
      end
    end

    {:noreply, state}
  end

  defp parse_member(data) do
    %WSocketIO.PresenceMember{
      client_id: data["clientId"] || "",
      data: data["data"],
      joined_at: data["joinedAt"] || 0
    }
  end
end

# ─── UUID helper ─────────────────────────────────────────────

defmodule UUID do
  @moduledoc false
  def uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
  end
end

# ─── Push Client ────────────────────────────────────────────

defmodule WSocketIO.Push do
  @moduledoc "REST-based push notifications client."

  defstruct [:base_url, :token, :app_id]

  def new(base_url, token, app_id) do
    %__MODULE__{base_url: base_url, token: token, app_id: app_id}
  end

  def register_fcm(%__MODULE__{} = push, opts) do
    post(push, "register", %{
      "memberId" => Keyword.fetch!(opts, :member_id),
      "platform" => "fcm",
      "subscription" => %{"deviceToken" => Keyword.fetch!(opts, :device_token)}
    })
  end

  def register_apns(%__MODULE__{} = push, opts) do
    post(push, "register", %{
      "memberId" => Keyword.fetch!(opts, :member_id),
      "platform" => "apns",
      "subscription" => %{"deviceToken" => Keyword.fetch!(opts, :device_token)}
    })
  end

  def send_to_member(%__MODULE__{} = push, member_id, opts) do
    post(push, "send", %{
      "memberId" => member_id,
      "payload" => Keyword.fetch!(opts, :payload)
    })
  end

  def broadcast(%__MODULE__{} = push, opts) do
    post(push, "broadcast", %{
      "payload" => Keyword.fetch!(opts, :payload)
    })
  end

  defp post(%__MODULE__{} = push, path, body) do
    url = "#{push.base_url}/api/push/#{path}"
    headers = [
      {"authorization", "Bearer #{push.token}"},
      {"x-app-id", push.app_id},
      {"content-type", "application/json"}
    ]
    Req.post!(url, headers: headers, json: body)
  end
end

# ─── Client (GenServer) ─────────────────────────────────────

defmodule WSocketIO.Client do
  @moduledoc "Main wSocket client — connects via WebSocket and manages channels."
  use GenServer

  defstruct [
    :url, :api_key, :ws_pid, :options,
    channels: %{}, subscribed: MapSet.new(), last_ts: 0,
    reconnect_attempts: 0, connected: false,
    on_connect: [], on_disconnect: [], on_error: []
  ]

  # ── Public API ──

  def start_link(url, api_key, opts \\ []) do
    options = %{
      auto_reconnect: Keyword.get(opts, :auto_reconnect, true),
      max_reconnect_attempts: Keyword.get(opts, :max_reconnect_attempts, 10),
      reconnect_delay: Keyword.get(opts, :reconnect_delay, 1000),
      token: Keyword.get(opts, :token),
      recover: Keyword.get(opts, :recover, true)
    }

    GenServer.start_link(__MODULE__, %__MODULE__{url: url, api_key: api_key, options: options})
  end

  def connect(pid), do: GenServer.call(pid, :connect)
  def disconnect(pid), do: GenServer.call(pid, :disconnect)
  def connected?(pid), do: GenServer.call(pid, :connected?)
  def channel(pid, name), do: GenServer.call(pid, {:channel, name})
  def on_connect(pid, cb), do: GenServer.call(pid, {:on, :connect, cb})
  def on_disconnect(pid, cb), do: GenServer.call(pid, {:on, :disconnect, cb})
  def on_error(pid, cb), do: GenServer.call(pid, {:on, :error, cb})

  # ── Callbacks ──

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:connect, _from, state) do
    ws_url = build_url(state)
    parent = self()

    {:ok, ws_pid} = WebSockex.start_link(ws_url, WSocketIO.WSHandler, %{parent: parent}, [])
    {:reply, :ok, %{state | ws_pid: ws_pid}}
  end

  def handle_call(:disconnect, _from, state) do
    if state.ws_pid, do: WebSockex.cast(state.ws_pid, :close)
    {:reply, :ok, %{state | connected: false}}
  end

  def handle_call(:connected?, _from, state) do
    {:reply, state.connected, state}
  end

  def handle_call({:channel, name}, _from, state) do
    if Map.has_key?(state.channels, name) do
      {:reply, state.channels[name], state}
    else
      send_fn = fn msg ->
        if state.ws_pid do
          WebSockex.send_frame(state.ws_pid, {:text, Jason.encode!(msg)})
        end
      end
      {:ok, ch_pid} = WSocketIO.Channel.start_link(name, send_fn)
      {:reply, ch_pid, %{state | channels: Map.put(state.channels, name, ch_pid)}}
    end
  end

  def handle_call({:on, :connect, cb}, _from, state) do
    {:reply, :ok, %{state | on_connect: state.on_connect ++ [cb]}}
  end

  def handle_call({:on, :disconnect, cb}, _from, state) do
    {:reply, :ok, %{state | on_disconnect: state.on_disconnect ++ [cb]}}
  end

  def handle_call({:on, :error, cb}, _from, state) do
    {:reply, :ok, %{state | on_error: state.on_error ++ [cb]}}
  end

  @impl true
  def handle_info(:ws_connected, state) do
    state = %{state | connected: true, reconnect_attempts: 0}

    if state.options.recover && MapSet.size(state.subscribed) > 0 && state.last_ts > 0 do
      resume_data = Jason.encode!(%{channels: MapSet.to_list(state.subscribed), since: state.last_ts})
      token = Base.url_encode64(resume_data, padding: false)
      send_ws(state, %{"action" => "resume", "token" => token})
    else
      Enum.each(state.subscribed, fn ch ->
        send_ws(state, %{"action" => "subscribe", "channel" => ch})
      end)
    end

    Enum.each(state.on_connect, fn cb -> cb.() end)
    {:noreply, state}
  end

  def handle_info({:ws_message, raw}, state) do
    case Jason.decode(raw) do
      {:ok, msg} -> {:noreply, handle_message(msg, state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info({:ws_disconnected, code}, state) do
    state = %{state | connected: false}
    Enum.each(state.on_disconnect, fn cb -> cb.(code) end)
    maybe_reconnect(state)
    {:noreply, state}
  end

  def handle_info({:ws_error, reason}, state) do
    Enum.each(state.on_error, fn cb -> cb.(reason) end)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    if !state.connected do
      handle_call(:connect, nil, state)
    end
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  # ── Private ──

  defp build_url(state) do
    sep = if String.contains?(state.url, "?"), do: "&", else: "?"
    url = "#{state.url}#{sep}key=#{state.api_key}"
    if state.options.token, do: "#{url}&token=#{state.options.token}", else: url
  end

  defp send_ws(state, msg) do
    if state.ws_pid do
      WebSockex.send_frame(state.ws_pid, {:text, Jason.encode!(msg)})
    end
  end

  defp handle_message(%{"action" => "message"} = msg, state) do
    channel_name = msg["channel"]
    ch_pid = state.channels[channel_name]

    if ch_pid do
      ts = msg["timestamp"] || :os.system_time(:millisecond)
      meta = %WSocketIO.MessageMeta{id: msg["id"] || "", channel: channel_name, timestamp: ts}
      WSocketIO.Channel.handle_message(ch_pid, msg["data"], meta)
      %{state | last_ts: max(ts, state.last_ts)}
    else
      state
    end
  end

  defp handle_message(%{"action" => "subscribed", "channel" => ch}, state) do
    %{state | subscribed: MapSet.put(state.subscribed, ch)}
  end

  defp handle_message(%{"action" => "unsubscribed", "channel" => ch}, state) do
    %{state | subscribed: MapSet.delete(state.subscribed, ch)}
  end

  defp handle_message(%{"action" => "history", "channel" => ch} = msg, state) do
    ch_pid = state.channels[ch]

    if ch_pid do
      messages = (msg["messages"] || [])
        |> Enum.map(fn m ->
          %WSocketIO.HistoryMessage{
            id: m["id"] || "", channel: ch, data: m["data"],
            publisher_id: m["publisherId"] || "",
            timestamp: m["timestamp"] || 0, sequence: m["sequence"] || 0
          }
        end)
      result = %WSocketIO.HistoryResult{channel: ch, messages: messages, has_more: msg["hasMore"] == true}
      WSocketIO.Channel.handle_history_result(ch_pid, result)
    end

    state
  end

  defp handle_message(%{"action" => action, "channel" => ch} = msg, state)
       when action in ["presence.enter", "presence.leave", "presence.update", "presence.members"] do
    ch_pid = state.channels[ch]
    if ch_pid, do: WSocketIO.Channel.handle_presence_event(ch_pid, action, msg)
    state
  end

  defp handle_message(%{"action" => "error"} = msg, state) do
    err = msg["error"] || "Unknown error"
    Enum.each(state.on_error, fn cb -> cb.(err) end)
    state
  end

  defp handle_message(_, state), do: state

  defp maybe_reconnect(state) do
    if state.options.auto_reconnect && state.reconnect_attempts < state.options.max_reconnect_attempts do
      delay = state.options.reconnect_delay * (state.reconnect_attempts + 1)
      Process.send_after(self(), :reconnect, delay)
    end
  end
end

# ─── WebSocket Handler ───────────────────────────────────────

defmodule WSocketIO.WSHandler do
  @moduledoc false
  use WebSockex

  @impl true
  def handle_connect(_conn, state) do
    send(state.parent, :ws_connected)
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    send(state.parent, {:ws_message, msg})
    {:ok, state}
  end

  def handle_frame(_, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    code = case reason do
      {:remote, code, _} -> code
      _ -> 1000
    end
    send(state.parent, {:ws_disconnected, code})
    {:ok, state}
  end

  @impl true
  def handle_cast(:close, state) do
    {:close, state}
  end
end
