defmodule EctoLiteFS.ConfigTest do
  use ExUnit.Case, async: true

  alias EctoLiteFS.Config

  describe "new!/1" do
    test "returns config struct with valid options" do
      config = Config.new!(repo: MyApp.Repo, name: :my_litefs)

      assert %Config{} = config
      assert config.repo == MyApp.Repo
      assert config.name == :my_litefs
      assert config.primary_file == "/litefs/.primary"
      assert config.poll_interval == 30_000
      assert config.event_stream_url == "http://localhost:20202/events"
      assert config.table_name == "_ecto_litefs_primary"
      assert config.cache_ttl == 5_000
    end

    test "allows overriding optional values" do
      config =
        Config.new!(
          repo: MyApp.Repo,
          name: :my_litefs,
          primary_file: "/custom/.primary",
          poll_interval: 10_000,
          event_stream_url: "http://custom:8080/events",
          table_name: "_custom_primary",
          cache_ttl: 1_000
        )

      assert config.primary_file == "/custom/.primary"
      assert config.poll_interval == 10_000
      assert config.event_stream_url == "http://custom:8080/events"
      assert config.table_name == "_custom_primary"
      assert config.cache_ttl == 1_000
    end

    test "raises when :repo is missing" do
      assert_raise ArgumentError, "EctoLiteFS.Config requires :repo option", fn ->
        Config.new!(name: :my_litefs)
      end
    end

    test "raises when :name is missing" do
      assert_raise ArgumentError, "EctoLiteFS.Config requires :name option", fn ->
        Config.new!(repo: MyApp.Repo)
      end
    end

    test "raises when :repo is not an atom" do
      assert_raise ArgumentError, "EctoLiteFS.Config :repo must be an atom", fn ->
        Config.new!(repo: "MyApp.Repo", name: :my_litefs)
      end
    end

    test "raises when :name is not an atom" do
      assert_raise ArgumentError, "EctoLiteFS.Config :name must be an atom", fn ->
        Config.new!(repo: MyApp.Repo, name: "not_an_atom")
      end
    end

    test "raises when :poll_interval is not a positive integer" do
      assert_raise ArgumentError, ~r/:poll_interval must be a positive integer/, fn ->
        Config.new!(repo: MyApp.Repo, name: :my_litefs, poll_interval: -1)
      end

      assert_raise ArgumentError, ~r/:poll_interval must be a positive integer/, fn ->
        Config.new!(repo: MyApp.Repo, name: :my_litefs, poll_interval: 0)
      end

      assert_raise ArgumentError, ~r/:poll_interval must be a positive integer/, fn ->
        Config.new!(repo: MyApp.Repo, name: :my_litefs, poll_interval: "1000")
      end
    end

    test "raises when :cache_ttl is not a positive integer" do
      assert_raise ArgumentError, ~r/:cache_ttl must be a positive integer/, fn ->
        Config.new!(repo: MyApp.Repo, name: :my_litefs, cache_ttl: -1)
      end
    end
  end
end
