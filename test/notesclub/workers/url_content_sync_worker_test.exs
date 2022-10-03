defmodule UrlContentSyncWorkerTest do
  use Notesclub.DataCase

  import ExUnit.CaptureLog
  import Mock

  alias Notesclub.Workers.UrlContentSyncWorker
  alias Notesclub.AccountsFixtures
  alias Notesclub.ReposFixtures
  alias Notesclub.NotebooksFixtures
  alias Notesclub.Notebooks
  alias Notesclub.ReqTools

  @valid_response %Req.Response{
    status: 200,
    body: """
    Classifying handwritten digits
    Mix.install([
      {:axon, github: \"elixir-nx/axon\"},
      ...
    """
  }

  @not_found_404_response %Req.Response{
    status: 404,
    body: ""
  }

  setup do
    user = AccountsFixtures.user_fixture(%{username: "elixir-nx"})
    repo = ReposFixtures.repo_fixture(%{name: "axon", default_branch: "main"})

    notebook =
      NotebooksFixtures.notebook_fixture(%{
        github_html_url:
          "https://github.com/elixir-nx/axon/blob/432e3ed23232424/notebooks/vision/mnist.livemd",
        user_id: user.id,
        repo_id: repo.id,
        content: "My Elixir notebook",
        url: "https://github.com/elixir-nx/axon/blob/main/notebooks/vision/mnist.livemd"
      })

    %{notebook: notebook}
  end

  describe "UrlContentSyncWorker" do
    test "perform/1 downloads url content and updates notebook", %{notebook: notebook} do
      with_mocks([
        {ReqTools, [:passthrough], [requests_enabled?: fn -> true end]},
        {Req, [:passthrough],
         [
           get:
             fn "https://raw.githubusercontent.com/elixir-nx/axon/main/notebooks/vision/mnist.livemd" ->
               {:ok, @valid_response}
             end
         ]}
      ]) do
        # Run job
        {:ok, :synced} = perform_job(UrlContentSyncWorker, %{notebook_id: notebook.id})

        # It should have updated content and url
        notebook = Notebooks.get_notebook!(notebook.id)
        assert notebook.content == @valid_response.body

        assert notebook.url ==
                 "https://github.com/elixir-nx/axon/blob/main/notebooks/vision/mnist.livemd"
      end
    end

    test "perform/1 cancels when user is nil", %{notebook: notebook} do
      {:ok, notebook} = Notebooks.update_notebook(notebook, %{user_id: nil})

      # Run job
      assert capture_log(fn ->
               {:cancel, "user can't be nil. It needs to be preloaded."} =
                 perform_job(UrlContentSyncWorker, %{notebook_id: notebook.id})
             end) =~
               "get_urls/1 returned {:error, user can't be nil. It needs to be preloaded.}; notebook.id=#{notebook.id}"

      # content and url should have NOT changed:
      notebook = Notebooks.get_notebook!(notebook.id)
      assert notebook.content == "My Elixir notebook"

      assert notebook.url ==
               "https://github.com/elixir-nx/axon/blob/main/notebooks/vision/mnist.livemd"
    end

    test "perform/1 cancels when repo is nil", %{notebook: notebook} do
      {:ok, notebook} = Notebooks.update_notebook(notebook, %{repo_id: nil})

      # Run job
      assert capture_log(fn ->
               {:cancel, "repo can't be nil. It needs to be preloaded."} =
                 perform_job(UrlContentSyncWorker, %{notebook_id: notebook.id})
             end) =~
               "get_urls/1 returned {:error, repo can't be nil. It needs to be preloaded.}; notebook.id=#{notebook.id}"

      # content and url should have NOT changed:
      notebook = Notebooks.get_notebook!(notebook.id)
      assert notebook.content == "My Elixir notebook"

      assert notebook.url ==
               "https://github.com/elixir-nx/axon/blob/main/notebooks/vision/mnist.livemd"
    end

    test "perform/1 when request to default_branch_url returns 404, request github_html_url and set url=nil",
         %{notebook: notebook} do
      with_mocks([
        {ReqTools, [:passthrough], [requests_enabled?: fn -> true end]},
        {Req, [:passthrough],
         [
           get: fn url ->
             case url do
               "https://raw.githubusercontent.com/elixir-nx/axon/main/notebooks/vision/mnist.livemd" ->
                 {:ok, @not_found_404_response}

               "https://raw.githubusercontent.com/elixir-nx/axon/432e3ed23232424/notebooks/vision/mnist.livemd" ->
                 {:ok, @valid_response}
             end
           end
         ]}
      ]) do
        {:ok, notebook} = Notebooks.update_notebook(notebook, %{url: nil})

        # Run job
        {:ok, :synced} = perform_job(UrlContentSyncWorker, %{notebook_id: notebook.id})

        # It should have updated content
        notebook = Notebooks.get_notebook!(notebook.id)
        assert notebook.content == @valid_response.body

        # But url should be nil
        assert notebook.url == nil
      end
    end
  end
end