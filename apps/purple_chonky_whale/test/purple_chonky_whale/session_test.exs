defmodule PurpleChonkyWhale.SessionTest do
  use ExUnit.Case, async: false

  alias PurpleChonkyWhale.{Session, Sessions, ToolResult}
  alias Dexterous.Context

  setup do
    scope = :"session_test_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "pcw-session-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, ctx: Context.new(scope), scope: scope, dir: dir}
  end

  defp open_session(dir, scope, id) do
    {:ok, pid} = Session.start_link(id: id, dir: dir, scope: scope)
    pid
  end

  defp append_assistant(pid, calls) do
    Session.append(pid, :"assistant/message", %{
      "content" => "",
      "tool_calls" =>
        Enum.map(calls, fn {id, name} ->
          %{"id" => id, "name" => name, "input" => %{}}
        end)
    })
  end

  describe "the log" do
    test "append assigns the complete envelope, in order", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)

      {:ok, e1} = Session.append(pid, :"turn/start", %{})
      {:ok, e2} = Session.append(pid, :"user/message", %{"content" => "hi"})

      assert e1.seq == 0
      assert e2.seq == 1
      assert is_integer(e1.at)
      assert is_binary(e1.id)
      assert e1.parent_id == nil
      assert e2.parent_id == e1.id
      assert [^e1, ^e2] = Session.events(pid)
    end

    test "v1 writes a physical header outside the event sequence", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)
      {:ok, event} = Session.append(pid, :"user/message", %{"content" => "hi"})

      [header_line, event_line] =
        dir |> Path.join("session-s1.jsonl") |> File.stream!() |> Enum.to_list()

      header = Jason.decode!(header_line)
      stored = Jason.decode!(event_line)

      assert header["type"] == "session"
      assert header["version"] == 1
      assert header["id"] == "s1"
      refute Map.has_key?(header, "seq")
      assert stored["seq"] == event.seq
      assert stored["id"] == event.id
      assert stored["parent_id"] == nil
      assert is_integer(stored["at"])
    end

    test "every append is broadcast as a session/event", %{dir: dir, scope: scope, ctx: ctx} do
      test_pid = self()

      {:ok, _} =
        Context.on(ctx, :"session/event", fn %{session: id, event: event} ->
          send(test_pid, {:session_event, id, event})
        end)

      pid = open_session(dir, scope, :s1)
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "hi"})

      assert_received {:session_event, :s1, %{type: :"user/message", seq: 0}}
    end

    test "invalid UTF-8 in a payload is scrubbed, never fatal", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :gbk)
      {:ok, _} = append_assistant(pid, [{"call_1", "bash"}])

      # GBK-encoded console output, as captured by a tool on a Chinese
      # Windows machine: not valid UTF-8.
      {:ok, event} =
        Session.append(pid, :"tool/result", %{
          "tool_call_id" => "call_1",
          "name" => "bash",
          "output" => <<199, 253, 10>>
        })

      assert Process.alive?(pid)
      assert String.valid?(event.data["output"])

      GenServer.stop(pid)
      pid = open_session(dir, scope, :gbk)
      assert [_assistant, %{data: %{"output" => output}}] = Session.events(pid)
      assert String.valid?(output)
    end

    test "reopening v1 replays stable event identities", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)
      {:ok, first} = Session.append(pid, :"user/message", %{"content" => "hello"})
      {:ok, second} = Session.append(pid, :"assistant/message", %{"content" => "hi there"})
      GenServer.stop(pid)

      pid = open_session(dir, scope, :s1)

      assert [^first, ^second] = Session.events(pid)
      assert first.data == %{"content" => "hello"}
      assert second.seq == 1
      assert second.parent_id == first.id
    end

    test "an event type no code references round-trips as a string", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)
      {:ok, first} = Session.append(pid, :"user/message", %{"content" => "hi"})

      # Simulate a future format: a valid v1 event whose type is unknown here.
      File.write!(
        Path.join(dir, "session-s1.jsonl"),
        Jason.encode!(%{
          "seq" => 1,
          "id" => "evt_future",
          "parent_id" => first.id,
          "type" => "future/thing",
          "at" => System.system_time(:millisecond),
          "data" => %{}
        }) <> "\n",
        [:append]
      )

      GenServer.stop(pid)
      pid = open_session(dir, scope, :s1)

      assert [%{type: :"user/message"}, %{type: "future/thing"}] = Session.events(pid)
      # Unknown types are not model-visible.
      assert [%{role: :user}] = Session.messages(pid)
    end

    test "legacy v0 keeps its disk shape and gains the current envelope in memory", %{
      dir: dir,
      scope: scope
    } do
      File.mkdir_p!(dir)
      path = Path.join(dir, "session-old.jsonl")

      File.write!(path, [
        Jason.encode!(%{
          "seq" => 0,
          "type" => "user/message",
          "at" => "2026-01-02T03:04:05Z",
          "data" => %{"content" => "old"}
        }) <> "\n"
      ])

      pid = open_session(dir, scope, :old)
      assert [legacy] = Session.events(pid)
      assert legacy.id == "evt_legacy_0"
      assert legacy.parent_id == nil
      assert is_integer(legacy.at)

      {:ok, appended} = Session.append(pid, :"user/message", %{"content" => "new"})
      assert appended.id == "evt_legacy_1"
      assert appended.parent_id == legacy.id
      GenServer.stop(pid)

      lines = path |> File.stream!() |> Enum.to_list()
      assert length(lines) == 2
      refute Jason.decode!(hd(lines))["type"] == "session"

      stored = Jason.decode!(List.last(lines))
      assert stored["seq"] == 1
      refute Map.has_key?(stored, "id")
      assert is_binary(stored["at"])

      pid = open_session(dir, scope, :old)
      assert [_legacy, ^appended] = Session.events(pid)
    end

    test "tool results reject unknown and duplicate calls within a batch", %{
      dir: dir,
      scope: scope
    } do
      pid = open_session(dir, scope, :s1)

      assert {:error, %{type: :unknown_tool_call}} =
               Session.append(pid, :"tool/result", %{
                 "tool_call_id" => "missing",
                 "name" => "calc",
                 "output" => "4"
               })

      {:ok, _} = append_assistant(pid, [{"call_1", "calc"}])
      result = ToolResult.from_result("call_1", "calc", {:ok, "4"})
      {:ok, _} = Session.append(pid, :"tool/result", %{"message" => result})

      assert {:error, %{type: :duplicate_tool_result}} =
               Session.append(pid, :"tool/result", %{"message" => result})

      # Providers are expected to unique ids, but a later batch may reuse one.
      {:ok, _} = append_assistant(pid, [{"call_1", "calc"}])
      assert {:ok, _} = Session.append(pid, :"tool/result", %{"message" => result})
    end
  end

  describe "the projection" do
    test "folds message events into ReqLLM messages, skipping markers", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)

      {:ok, _} = Session.append(pid, :"system/message", %{"content" => "be brief"})
      {:ok, _} = Session.append(pid, :"turn/start", %{})
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "2+2?"})
      {:ok, _} = append_assistant(pid, [{"call_1", "calc"}])

      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "tool_call_id" => "call_1",
          "name" => "calc",
          "output" => "4"
        })

      {:ok, _} = Session.append(pid, :"assistant/message", %{"content" => "4"})
      {:ok, _} = Session.append(pid, :"turn/end", %{})

      assert [system, user, assistant_call, tool_result, assistant] = Session.messages(pid)
      assert system.role == :system
      assert user.role == :user
      assert assistant_call.role == :assistant
      assert tool_result.role == :tool
      assert tool_result.metadata.is_error == false
      assert [%{type: :text, text: "4"}] = tool_result.content
      assert assistant.role == :assistant

      assert [%{type: :text, text: "4"}] = assistant.content
    end

    test "userId marks the speaker in multi-actor logs; single-user logs project unchanged", %{
      dir: dir,
      scope: scope
    } do
      pid = open_session(dir, scope, :multi)

      {:ok, alice_event} =
        Session.append(pid, :"user/message", %{"userId" => "alice", "content" => "hi"})

      {:ok, _} = Session.append(pid, :"user/message", %{"userId" => "bob", "content" => "yo"})
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "plain"})

      assert [alice, bob, plain] = Session.messages(pid)
      assert [%{type: :text, text: "alice: hi"}] = alice.content
      assert [%{type: :text, text: "bob: yo"}] = bob.content
      assert [%{type: :text, text: "plain"}] = plain.content

      # The actor is durable: it persists in the event payload.
      assert alice_event.data["userId"] == "alice"
      GenServer.stop(pid)
      pid = open_session(dir, scope, :multi)
      assert [%{data: %{"userId" => "alice"}} | _] = Session.events(pid)
    end

    test "user message parts carry image attachments through blob storage and projection", %{
      dir: dir,
      scope: scope
    } do
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 9, 9>>
      pid = open_session(dir, scope, :attach)

      {:ok, event} =
        Session.append(pid, :"user/message", %{
          "userId" => "alice",
          "content" => "what is this?",
          "parts" => [ToolResult.image_part(png, "image/png")]
        })

      [part] = event.data["parts"]
      refute Map.has_key?(part, "data")
      assert part["blob"] =~ ".png"

      assert [user] = Session.messages(pid)

      assert [
               %{type: :text, text: "alice: what is this?"},
               %{type: :image, data: ^png, media_type: "image/png"}
             ] = user.content

      # A missing blob degrades that part to a text placeholder.
      File.rm!(Path.join([dir, "blobs", part["blob"]]))
      assert [user] = Session.messages(pid)
      assert [%{type: :text}, %{type: :text, text: placeholder}] = user.content
      assert placeholder =~ "image unavailable"
    end

    test "canonical results preserve JSON success and structured errors", %{
      dir: dir,
      scope: scope
    } do
      pid = open_session(dir, scope, :s1)
      {:ok, _} = append_assistant(pid, [{"ok", "calc"}, {"bad", "calc"}])

      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "message" => ToolResult.from_result("ok", "calc", {:ok, %{"answer" => 42}})
        })

      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "message" =>
            ToolResult.from_result("bad", "calc", {:error, %{type: :denied, message: "no"}})
        })

      assert [_assistant, ok, bad] = Session.messages(pid)
      assert [%{type: :text, text: ~s({"answer":42})}] = ok.content
      assert ok.metadata.is_error == false
      assert [%{type: :text, text: "no"}] = bad.content
      assert bad.metadata.is_error == true

      assert [_assistant, _ok, %{data: %{"message" => bad_event}}] = Session.events(pid)
      assert bad_event["details"]["error"]["type"] == "denied"
      assert bad_event["isError"] == true
    end

    test "tool results precede deferred input and follow assistant call order", %{
      dir: dir,
      scope: scope
    } do
      pid = open_session(dir, scope, :s1)
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "work"})
      {:ok, _} = append_assistant(pid, [{"c1", "read"}, {"c2", "read"}])

      # Results may settle out of order; steering may arrive before the batch closes.
      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "message" => ToolResult.from_result("c2", "read", {:ok, "second"})
        })

      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "steer"})

      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "message" => ToolResult.from_result("c1", "read", {:ok, "first"})
        })

      {:ok, _} = Session.append(pid, :"assistant/message", %{"content" => "done"})

      assert [user, _call, first, second, steer, assistant] = Session.messages(pid)
      assert user.role == :user
      assert first.tool_call_id == "c1"
      assert second.tool_call_id == "c2"
      assert steer.role == :user
      assert [%{type: :text, text: "steer"}] = steer.content
      assert assistant.role == :assistant

      # The durable chronology is unchanged even though the provider view is reordered.
      assert Enum.map(Session.events(pid), & &1.type) == [
               :"user/message",
               :"assistant/message",
               :"tool/result",
               :"user/message",
               :"tool/result",
               :"assistant/message"
             ]
    end

    test "an unsettled tool batch refuses provider projection", %{dir: dir, scope: scope} do
      pid = open_session(dir, scope, :s1)
      {:ok, _} = append_assistant(pid, [{"c1", "read"}])

      assert_raise ArgumentError, ~r/unsettled tool calls/, fn -> Session.messages(pid) end
    end

    test "image parts are stored as blobs and rehydrated on projection", %{
      dir: dir,
      scope: scope
    } do
      png = <<137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3>>
      pid = open_session(dir, scope, :img)
      {:ok, _} = append_assistant(pid, [{"c1", "read"}])

      {:ok, event} =
        Session.append(pid, :"tool/result", %{
          "message" =>
            ToolResult.from_result(
              "c1",
              "read",
              {:ok, {:parts, [ToolResult.image_part(png, "image/png")]}}
            )
        })

      [part] = event.data["message"]["content"]
      refute Map.has_key?(part, "data")
      assert part["type"] == "image"
      assert part["mediaType"] == "image/png"
      assert part["bytes"] == byte_size(png)
      assert part["blob"] =~ ".png"
      assert File.read!(Path.join([dir, "blobs", part["blob"]])) == png

      # The durable log holds the reference, not the payload.
      refute File.read!(Path.join(dir, "session-img.jsonl")) =~ Base.encode64(png)

      assert [_assistant, tool] = Session.messages(pid)
      assert [%{type: :image, data: ^png, media_type: "image/png"}] = tool.content

      # Reopening replays from disk and rehydrates the same way.
      GenServer.stop(pid)
      pid = open_session(dir, scope, :img)
      assert [_assistant, tool] = Session.messages(pid)
      assert [%{type: :image, data: ^png}] = tool.content

      # A missing blob degrades to a text placeholder, never a projection failure.
      File.rm!(Path.join([dir, "blobs", part["blob"]]))
      GenServer.stop(pid)
      pid = open_session(dir, scope, :img)
      assert [_assistant, tool] = Session.messages(pid)
      assert [%{type: :text, text: text}] = tool.content
      assert text =~ "image unavailable"
    end

    test "seal_unsettled/2 distinguishes started (outcome_unknown) vs not_started (cancelled) calls and binds runId",
         %{
           dir: dir,
           scope: scope
         } do
      pid = open_session(dir, scope, :interrupted)
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "read all three"})
      {:ok, _} = append_assistant(pid, [{"c1", "read"}, {"c2", "write"}, {"c3", "read"}])

      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "runId" => "run_1",
          "message" => ToolResult.from_result("c1", "read", {:ok, "first file"})
        })

      # Simulate a crash and reopen with c2 (started) and c3 (not started) still unsettled.
      GenServer.stop(pid)
      pid = open_session(dir, scope, :interrupted)

      assert_raise ArgumentError, ~r/unsettled tool calls: c2, c3/, fn ->
        Session.messages(pid)
      end

      assert {:ok, [sealed_c2, sealed_c3]} =
               Session.seal_unsettled(pid,
                 reason: "turn aborted",
                 started_call_ids: ["c2"],
                 run_id: "run_1"
               )

      assert sealed_c2.type == :"tool/result"
      assert sealed_c2.data["runId"] == "run_1"
      assert sealed_c2.data["message"]["toolCallId"] == "c2"
      assert sealed_c2.data["message"]["isError"] == true
      assert sealed_c2.data["message"]["details"]["error"]["type"] == "outcome_unknown"
      assert sealed_c2.data["message"]["details"]["error"]["state"] == "started"

      assert sealed_c3.type == :"tool/result"
      assert sealed_c3.data["runId"] == "run_1"
      assert sealed_c3.data["message"]["toolCallId"] == "c3"
      assert sealed_c3.data["message"]["isError"] == true
      assert sealed_c3.data["message"]["details"]["error"]["type"] == "cancelled"
      assert sealed_c3.data["message"]["details"]["error"]["state"] == "not_started"

      assert [_user, _assistant, r1, r2, r3] = Session.messages(pid)
      assert r1.tool_call_id == "c1"
      assert r1.metadata.is_error == false
      assert r2.tool_call_id == "c2"
      assert r2.metadata.is_error == true
      assert [%{type: :text, text: r2_text}] = r2.content
      assert r2_text =~ "do not repeat non-idempotent work blindly"
      assert r3.tool_call_id == "c3"
      assert r3.metadata.is_error == true
      assert [%{type: :text, text: "turn aborted"}] = r3.content
    end

    test "rejects a late tool/result carrying a stale runId from an older run", %{
      dir: dir,
      scope: scope
    } do
      pid = open_session(dir, scope, :stale_run)

      {:ok, _} =
        Session.append(pid, :"assistant/message", %{
          "runId" => "run_new",
          "content" => "",
          "tool_calls" => [%{"id" => "call_1", "name" => "read", "input" => %{}}]
        })

      assert {:error, %{type: :stale_run_result}} =
               Session.append(pid, :"tool/result", %{
                 "runId" => "run_old",
                 "message" => ToolResult.from_result("call_1", "read", {:ok, "stale"})
               })

      assert {:ok, _} =
               Session.append(pid, :"tool/result", %{
                 "runId" => "run_new",
                 "message" => ToolResult.from_result("call_1", "read", {:ok, "fresh"})
               })
    end

    test "assistant thinking and signed reasoning_details round-trip through disk and projection",
         %{
           dir: dir,
           scope: scope
         } do
      pid = open_session(dir, scope, :thinking)

      {:ok, _} =
        Session.append(pid, :"assistant/message", %{
          "content" => "I will check the file.",
          "thinking" => "Need to inspect config first.",
          "reasoning_details" => [
            %{
              "text" => "Need to inspect config first.",
              "signature" => "sig_anthropic_123",
              "encrypted" => true,
              "provider" => "anthropic",
              "index" => 0
            }
          ],
          "tool_calls" => [
            %{
              "id" => "call_1",
              "name" => "read",
              "input" => %{"file_path" => "mix.exs"},
              "metadata" => %{"thought_signature" => "sig_gemini_456"}
            }
          ]
        })

      {:ok, _} =
        Session.append(pid, :"tool/result", %{
          "message" => ToolResult.from_result("call_1", "read", {:ok, "defmodule..."})
        })

      GenServer.stop(pid)
      pid = open_session(dir, scope, :thinking)

      assert [assistant, _tool] = Session.messages(pid)

      assert [
               %{type: :text, text: "I will check the file."},
               %{type: :thinking, text: "Need to inspect config first."}
             ] = assistant.content

      assert [
               %ReqLLM.Message.ReasoningDetails{
                 text: "Need to inspect config first.",
                 signature: "sig_anthropic_123",
                 encrypted?: true,
                 provider: :anthropic,
                 index: 0
               }
             ] = assistant.reasoning_details

      assert [tool_call] = assistant.tool_calls
      assert ReqLLM.ToolCall.metadata(tool_call) == %{thought_signature: "sig_gemini_456"}
    end
  end

  describe "the :sessions service" do
    test "provides a store that opens, lists and reopens sessions", %{ctx: ctx, dir: dir} do
      {:ok, _fiber} = Context.use(ctx, Sessions, dir: dir)

      sessions =
        eventually(fn ->
          case Context.get(ctx, :sessions) do
            {:ok, sessions} -> sessions
            :error -> nil
          end
        end)

      {:ok, pid} = Sessions.open(sessions, "chat-1")
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "hi"})

      # Opening twice returns the same process.
      assert {:ok, ^pid} = Sessions.open(sessions, "chat-1")
      assert ["chat-1"] = Sessions.list(sessions)

      assert :ok = Sessions.close(sessions, pid)
      assert ["chat-1"] = Sessions.list(sessions)

      # The log survives the process: reopening replays it.
      {:ok, pid2} = Sessions.open(sessions, "chat-1")
      assert [%{type: :"user/message"}] = Session.events(pid2)
    end

    test "open/3 records the caller's cwd in a fresh session header", %{ctx: ctx, dir: dir} do
      {:ok, _fiber} = Context.use(ctx, Sessions, dir: dir)

      sessions =
        eventually(fn ->
          case Context.get(ctx, :sessions) do
            {:ok, sessions} -> sessions
            :error -> nil
          end
        end)

      {:ok, pid} = Sessions.open(sessions, "at-work", cwd: "d:/somewhere/else")
      {:ok, _} = Session.append(pid, :"user/message", %{"content" => "hi"})

      header =
        dir
        |> Path.join("session-at-work.jsonl")
        |> File.stream!()
        |> Enum.take(1)
        |> hd()
        |> Jason.decode!()

      assert header["cwd"] == "d:/somewhere/else"

      # Opening an existing log ignores the option: the header is history.
      :ok = Sessions.close(sessions, pid)
      {:ok, pid2} = Sessions.open(sessions, "at-work", cwd: "d:/elsewhere")
      assert [%{type: :"user/message"}] = Session.events(pid2)

      header =
        dir
        |> Path.join("session-at-work.jsonl")
        |> File.stream!()
        |> Enum.take(1)
        |> hd()
        |> Jason.decode!()

      assert header["cwd"] == "d:/somewhere/else"
    end
  end

  describe "opening a damaged log" do
    test "drops a torn trailing line and keeps everything before it", %{dir: dir, scope: scope} do
      path = Path.join(dir, "session-torn.jsonl")

      header =
        ~s({"type":"session","version":1,"id":"torn","created_at":0,"cwd":"."})

      event =
        ~s({"seq":0,"id":"evt_a","parent_id":null,"type":"user/message","at":0,"data":{"content":"before the crash"}})

      # A crash in the middle of an append leaves exactly this: one complete
      # event, then half of the next line and no trailing newline.
      File.write!(path, header <> "\n" <> event <> "\n" <> ~s({"seq":1,"id":"evt_b","parent_))

      pid = open_session(dir, scope, :torn)

      assert [stored] = Session.events(pid)
      assert stored.id == "evt_a"

      # The file itself was repaired, not just the in-memory view.
      lines = Enum.to_list(File.stream!(path))
      assert length(lines) == 2
      assert String.ends_with?(List.last(lines), "}\n")

      # And the log keeps working: the next event continues the sequence.
      {:ok, next} = Session.append(pid, :"user/message", %{"content" => "after"})
      assert next.seq == 1
      assert next.parent_id == "evt_a"
    end

    test "moves a corrupt log aside instead of refusing to open", %{dir: dir, scope: scope} do
      path = Path.join(dir, "session-corrupt.jsonl")

      header =
        ~s({"type":"session","version":1,"id":"corrupt","created_at":0,"cwd":"."})

      good =
        ~s({"seq":0,"id":"evt_a","parent_id":null,"type":"user/message","at":0,"data":{"content":"first"}})

      # Newline-terminated garbage in the middle: not a torn write, so it
      # cannot be repaired by dropping the tail.
      File.write!(path, header <> "\n" <> good <> "\n" <> "{not json}\n" <> good <> "\n")

      pid = open_session(dir, scope, :corrupt)

      # A usable, empty session — nothing is lost from disk.
      assert Session.events(pid) == []

      refute File.exists?(path)

      [quarantined] =
        dir
        |> File.ls!()
        |> Enum.filter(&String.starts_with?(&1, "session-corrupt.jsonl.corrupt-"))

      assert File.read!(Path.join(dir, quarantined)) =~ "{not json}"
    end

    test "an unsupported format is a typed error, not a decode crash", %{dir: dir, scope: scope} do
      path = Path.join(dir, "session-future.jsonl")
      File.write!(path, ~s({"type":"session","version":99,"id":"future"}) <> "\n")

      # A linked caller still sees the exit signal; what changes is the shape:
      # a typed reason a supervisor (and `Sessions.open/3`) can report.
      Process.flag(:trap_exit, true)

      assert {:error, {:unsupported_session_format, 99}} =
               Session.start_link(id: :future, dir: dir, scope: scope)
    end

    test ":sync is honoured per log", %{dir: dir, scope: scope} do
      {:ok, pid} = Session.start_link(id: :synced, dir: dir, scope: scope, sync: true)

      {:ok, event} = Session.append(pid, :"user/message", %{"content" => "durable"})
      assert event.seq == 0

      [header_line, event_line] =
        Enum.to_list(File.stream!(Path.join(dir, "session-synced.jsonl")))

      assert Jason.decode!(header_line)["type"] == "session"
      assert Jason.decode!(event_line)["id"] == event.id
    end
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: nil

  defp eventually(fun, attempts) do
    case fun.() do
      nil ->
        Process.sleep(10)
        eventually(fun, attempts - 1)

      other ->
        other
    end
  end
end
