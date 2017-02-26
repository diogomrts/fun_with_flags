defmodule FunWithFlags.NotificationsTest do
  use ExUnit.Case, async: false
  import FunWithFlags.TestUtils
  import Mock

  alias FunWithFlags.Notifications


  describe "unique_id()" do
    test "it returns a string" do
      assert is_binary(Notifications.unique_id())
    end

    test "it always returns the same ID for the GenServer" do
      assert Notifications.unique_id() == Notifications.unique_id()
    end

    test "the ID changes if the GenServer restarts" do
      a = Notifications.unique_id()
      kill_process(Notifications)
      :timer.sleep(1)
      refute a == Notifications.unique_id()
    end
  end


  describe "payload_for(flag_name)" do
    test "it returns a 2 item list" do
      flag_name = unique_atom()

      output = Notifications.payload_for(flag_name)
      assert is_list(output)
      assert 2 == length(output)
    end

    test "the first one is the channel name, the second one is the flag
          name plus the unique_id for the GenServer" do
      flag_name = unique_atom()
      u_id = Notifications.unique_id()
      channel = "fun_with_flags_changes"

      assert [^channel, << blob :: binary >>] = Notifications.payload_for(flag_name)
      assert [^u_id, string] = String.split(blob, ":")
      assert ^flag_name = String.to_atom(string)
    end
  end


  test "it receives messages if something is published on Redis" do
    alias FunWithFlags.Store.Persistent

    u_id = Notifications.unique_id()
    channel = "fun_with_flags_changes"
    pubsub_receiver_pid = GenServer.whereis(:fun_with_flags_notifications)
    message = "foobar"

    with_mock(Notifications, [:passthrough], []) do
      Redix.command(Persistent, ["PUBLISH", channel, message])
      :timer.sleep(1)

      assert called(
        Notifications.handle_info(
          {
            :redix_pubsub,
            pubsub_receiver_pid,
            :message,
            %{channel: channel, payload: message}
          },
          u_id
        )
      )
    end
  end


  describe "integration: message handling" do
    alias FunWithFlags.Store.Persistent
    alias FunWithFlags.{Store, Config}


    test "when the message is not valid, it is ignored" do
      channel = "fun_with_flags_changes"
      
      with_mock(Store, [:passthrough], []) do
        Redix.command(Persistent, ["PUBLISH", channel, "foobar"])
        :timer.sleep(30)
        refute called(Store.reload(:foobar))
      end
    end


    test "when the message comes from this same process, it is ignored" do
      u_id = Notifications.unique_id()
      channel = "fun_with_flags_changes"
      message = "#{u_id}:foobar"
      
      with_mock(Store, [:passthrough], []) do
        Redix.command(Persistent, ["PUBLISH", channel, message])
        :timer.sleep(30)
        refute called(Store.reload(:foobar))
      end
    end


    test "when the message comes from another process, it reloads the flag" do
      another_u_id = Config.build_unique_id()
      refute another_u_id == Notifications.unique_id()

      channel = "fun_with_flags_changes"
      message = "#{another_u_id}:foobar"
      
      with_mock(Store, [:passthrough], []) do
        Redix.command(Persistent, ["PUBLISH", channel, message])
        :timer.sleep(30)
        assert called(Store.reload(:foobar))
      end
    end
  end


  describe "integration: side effects" do
    alias FunWithFlags.Store.{Cache,Persistent}
    alias FunWithFlags.{Store, Config, Gate, Flag}

    setup do
      name = unique_atom()
      gate = %Gate{type: :boolean, enabled: true}
      stored_flag = %Flag{name: name, gates: [gate]}

      gate2 = %Gate{type: :boolean, enabled: false}
      cached_flag = %Flag{name: name, gates: [gate2]}

      {:ok, ^stored_flag} = Persistent.put(name, gate)
      :timer.sleep(10)
      {:ok, ^cached_flag} = Cache.put(cached_flag)

      assert {:ok, ^stored_flag} = Persistent.get(name)
      assert {:ok, ^cached_flag} = Cache.get(name)

      refute match? ^stored_flag, cached_flag

      {:ok, name: name, stored_flag: stored_flag, cached_flag: cached_flag}
    end


    test "when the message is not valid, the Cached value is not changed", %{name: name, cached_flag: cached_flag} do
      channel = "fun_with_flags_changes"
      
      Redix.command(Persistent, ["PUBLISH", channel, to_string(name)])
      :timer.sleep(30)
      assert {:ok, ^cached_flag} = Cache.get(name)
    end


    test "when the message comes from this same process, the Cached value is not changed", %{name: name, cached_flag: cached_flag} do
      u_id = Notifications.unique_id()
      channel = "fun_with_flags_changes"
      message = "#{u_id}:#{to_string(name)}"
      
      Redix.command(Persistent, ["PUBLISH", channel, message])
      :timer.sleep(30)
      assert {:ok, ^cached_flag} = Cache.get(name)
    end


    test "when the message comes from another process, the Cached value is reloaded", %{name: name, cached_flag: cached_flag, stored_flag: stored_flag} do
      another_u_id = Config.build_unique_id()
      refute another_u_id == Notifications.unique_id()

      channel = "fun_with_flags_changes"
      message = "#{another_u_id}:#{to_string(name)}"
      
      assert {:ok, ^cached_flag} = Cache.get(name)
      Redix.command(Persistent, ["PUBLISH", channel, message])
      :timer.sleep(30)
      assert {:ok, ^stored_flag} = Cache.get(name)
    end
  end
end