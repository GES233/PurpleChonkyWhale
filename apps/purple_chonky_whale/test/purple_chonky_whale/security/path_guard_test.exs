defmodule PurpleChonkyWhale.Security.PathGuardTest do
  use ExUnit.Case, async: true

  alias PurpleChonkyWhale.Security.PathGuard
  alias PurpleChonkyWhale.Tools.{Edit, Glob, Grep, Read, Write}

  setup do
    base = Path.join(System.tmp_dir!(), "pcw-guard-test-#{System.unique_integer([:positive])}")
    workspace = Path.join(base, "workspace")
    outside = Path.join(base, "outside")
    # Sibling sharing the workspace's prefix to verify segment-aware matching.
    sibling = Path.join(base, "workspace_sibling")

    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.mkdir_p!(sibling)
    File.write!(Path.join(workspace, "in.txt"), "inside\n")
    File.write!(Path.join(outside, "secret.txt"), "outside-secret\n")
    File.write!(Path.join(sibling, "sib.txt"), "sibling\n")

    on_exit(fn -> File.rm_rf(base) end)

    {:ok,
     base: base,
     workspace: workspace,
     outside: outside,
     sibling: sibling,
     env: %{cwd: workspace}}
  end

  describe "workspace boundary" do
    test "allows reading and writing inside cwd", %{env: env, workspace: workspace} do
      assert {:ok, _} = PathGuard.authorize(env, "in.txt", :read)
      assert {:ok, _} = PathGuard.authorize(env, "nested/new.txt", :write)
      assert {:ok, _} = PathGuard.authorize(env, Path.join(workspace, "in.txt"), :read)
    end

    test "blocks traversal, absolute paths outside cwd, and prefix-sharing siblings", %{
      env: env,
      outside: outside,
      sibling: sibling
    } do
      assert {:error, msg} = PathGuard.authorize(env, "../outside/secret.txt", :read)
      assert msg =~ "path denied"

      assert {:error, msg} = PathGuard.authorize(env, Path.join(outside, "secret.txt"), :write)
      assert msg =~ "path denied"

      assert {:error, msg} = PathGuard.authorize(env, Path.join(sibling, "sib.txt"), :read)
      assert msg =~ "path denied"
    end

    test "blocks empty paths and NUL bytes", %{env: env} do
      assert {:error, _} = PathGuard.authorize(env, "", :read)
      assert {:error, _} = PathGuard.authorize(env, "foo\0bar", :read)
      assert {:error, _} = PathGuard.authorize(env, nil, :read)
    end

    test "honors explicit readable_roots and writable_roots", %{env: env, outside: outside} do
      read_env = Map.put(env, :readable_roots, [outside])
      assert {:ok, _} = PathGuard.authorize(read_env, Path.join(outside, "secret.txt"), :read)
      assert {:error, _} = PathGuard.authorize(read_env, Path.join(outside, "secret.txt"), :write)

      write_env = Map.put(env, :writable_roots, [outside])
      assert {:ok, _} = PathGuard.authorize(write_env, Path.join(outside, "new.txt"), :write)
    end

    test "blocks symlinks inside the workspace that point outside it", %{
      env: env,
      workspace: workspace,
      outside: outside
    } do
      link = Path.join(workspace, "escape_link")

      # Symlink creation requires developer mode / privileges on Windows;
      # match the repo's platform-guard idiom when absent.
      with :ok <- File.ln_s(outside, link) do
        assert {:error, msg} = PathGuard.authorize(env, "escape_link/secret.txt", :read)
        assert msg =~ "path denied"

        assert {:error, msg} = PathGuard.authorize(env, "escape_link/new.txt", :write)
        assert msg =~ "path denied"
      end
    end
  end

  describe "self-destruct floor on :write" do
    test "refuses writes to protected_dirs even when inside cwd", %{
      env: env,
      workspace: workspace
    } do
      protected = Path.join(workspace, "harness_state")
      File.mkdir_p!(protected)
      env = Map.put(env, :protected_dirs, [protected])

      assert {:error, msg} = PathGuard.authorize(env, "harness_state/session.jsonl", :write)
      assert msg =~ "protected directory"
      # Reading inside protected_dirs (when inside readable_roots) is still allowed.
      assert {:ok, _} = PathGuard.authorize(env, "harness_state/session.jsonl", :read)
    end

    test "refuses filesystem root and user home as writable roots or targets" do
      root =
        case :os.type() do
          {:win32, _} -> "C:/"
          _posix -> "/"
        end

      assert {:error, msg} = PathGuard.authorize(%{cwd: root}, "file.txt", :write)
      assert msg =~ "path denied"

      if home = System.user_home() do
        assert {:error, msg} = PathGuard.authorize(%{cwd: home}, "file.txt", :write)
        assert msg =~ "path denied"

        for subdir <- ~w(.ssh .dsh .pcw Desktop Documents) do
          target = Path.join([home, subdir, "probe.txt"])

          assert {:error, msg} =
                   PathGuard.authorize(
                     %{cwd: Path.join(home, subdir)},
                     target,
                     :write
                   )

          assert msg =~ "path denied"
        end
      end
    end
  end

  describe "built-in file tools enforce PathGuard" do
    test "read, write, edit, glob and grep all reject paths outside cwd", %{
      env: env,
      outside: outside
    } do
      target = Path.join(outside, "secret.txt")

      assert {:error, msg} = Read.execute(%{"file_path" => target}, env)
      assert msg =~ "path denied"

      assert {:error, msg} = Write.execute(%{"file_path" => target, "content" => "x"}, env)
      assert msg =~ "path denied"
      assert File.read!(target) == "outside-secret\n"

      assert {:error, msg} =
               Edit.execute(
                 %{"file_path" => target, "old_string" => "outside", "new_string" => "pwned"},
                 env
               )

      assert msg =~ "path denied"
      assert File.read!(target) == "outside-secret\n"

      assert {:error, msg} = Glob.execute(%{"pattern" => "*", "path" => outside}, env)
      assert msg =~ "path denied"

      assert {:error, msg} = Grep.execute(%{"pattern" => "secret", "path" => outside}, env)
      assert msg =~ "path denied"
    end
  end
end
