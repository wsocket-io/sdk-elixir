# wSocket SDK for Elixir

Official Elixir SDK for wSocket — realtime pub/sub, presence, history, and push notifications.

## Installation

Add `wsocket_io` to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:wsocket_io, "~> 0.1.0"}
  ]
end
```

Then run:

```bash
mix deps.get
```

## Quick Start

```elixir
{:ok, client} = WSocketIO.Client.start_link("wss://node00.wsocket.online", "your-api-key")

WSocketIO.Client.on_connect(client, fn ->
  IO.puts("Connected!")
end)

channel = WSocketIO.Client.channel(client, "chat")

WSocketIO.Channel.subscribe(channel, fn data, meta ->
  IO.inspect(data, label: "Received")
end)

WSocketIO.Channel.publish(channel, %{text: "Hello from Elixir!"})
```

## Presence

```elixir
channel = WSocketIO.Client.channel(client, "room")

WSocketIO.Presence.enter(channel, data: %{name: "Alice"})

WSocketIO.Presence.on_enter(channel, fn member ->
  IO.puts("#{member.client_id} entered")
end)

WSocketIO.Presence.on_leave(channel, fn member ->
  IO.puts("#{member.client_id} left")
end)

WSocketIO.Presence.get(channel)
WSocketIO.Presence.on_members(channel, fn members ->
  IO.puts("Online: #{length(members)}")
end)
```

## History

```elixir
WSocketIO.Channel.history(channel, limit: 50)
WSocketIO.Channel.on_history(channel, fn result ->
  Enum.each(result.messages, fn msg ->
    IO.puts("#{msg.publisher_id}: #{inspect(msg.data)}")
  end)
end)
```

## Push Notifications

```elixir
push = WSocketIO.Push.new("https://node00.wsocket.online", "secret", "app1")

# Register FCM device
WSocketIO.Push.register_fcm(push, device_token: fcm_token, member_id: "user-123")

# Send to a member
WSocketIO.Push.send_to_member(push, "user-123",
  payload: %{title: "New message", body: "You have a new message"})

# Broadcast
WSocketIO.Push.broadcast(push, payload: %{title: "Announcement", body: "Server update"})
```

## Requirements

- Elixir 1.14+
- Erlang/OTP 25+

## License

MIT
