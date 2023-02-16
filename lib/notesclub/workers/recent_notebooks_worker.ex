defmodule Notesclub.Workers.RecentNotebooksWorker do
  @moduledoc """
    Fetch and create or update recent notebooks from Github
  """

  use Oban.Worker, queue: :github_search, priority: 2

  alias Notesclub.{GithubAPI, Notebooks}
  alias Notesclub.Workers.{RecentNotebooksWorker, UrlContentSyncWorker}

  #  per_page is only 5 because GitHub Search API with high per_page
  #  often returns less files than we asked and in a different order
  @per_page 5
  #  Only the first 1000 search results are available via GitHub Search API
  @max 1000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"page" => page}}) do
    options = [per_page: @per_page, page: page, order: "desc"]

    with {:ok, %GithubAPI{notebooks_data: data}} <- GithubAPI.get(options),
         :ok <- save_and_enqueue_content_sync(data, length(data)) do
      enqueue_next_page(page)
    else
      {:error, error} ->
        {:error, "Retry. #{inspect(error)}"}

      _ ->
        {:error, "Retry. Unknown error."}
    end
  end

  defp enqueue_next_page(page) do
    if @per_page * page < @max do
      %{page: page + 1}
      |> RecentNotebooksWorker.new()
      |> Oban.insert()

      {:ok, "Done and enqueued another page"}
    else
      {:ok, "No more pages. All done."}
    end
  end

  defp save_and_enqueue_content_sync(notebooks_data, @per_page) do
    Enum.each(notebooks_data, fn notebook_data ->
      {:ok, notebook} = Notebooks.save_notebook(notebook_data)

      %{notebook_id: notebook.id}
      |> UrlContentSyncWorker.new()
      |> Oban.insert()
    end)

    :ok
  end

  defp save_and_enqueue_content_sync(_, _) do
    {:error, "Returned data did NOT match per_page."}
  end
end