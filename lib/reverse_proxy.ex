defmodule ReverseProxy do
  @moduledoc """
  A Plug based, reverse proxy server.

  `ReverseProxy` can act as a standalone service or as part of a plug
  pipeline in an existing application.

  From [Wikipedia](https://wikipedia.org/wiki/Reverse_proxy):

  > In computer networks, a reverse proxy is a type of proxy server
  > that retrieves resources on behalf of a client from one or more
  > servers. These resources are then returned to the client as
  > though they originated from the proxy server itself. While a
  > forward proxy acts as an intermediary for its associated clients
  > to contact any server, a reverse proxy acts as an intermediary
  > for its associated servers to be contacted by any client.
  """

  use Application
  @behaviour Plug
  require Logger

  @spec init(Keyword.t) :: Keyword.t
  def init(opts), do: opts

  @spec call(Plug.Conn.t, Keyword.t) :: Plug.Conn.t
  def call(conn, opts) do
    upstream = Keyword.get(opts, :upstream, "")
      |> URI.parse
      |> Map.to_list
      |> Enum.filter(fn {_, val} -> !!val end)
      |> keyword_rename(:path, :request_path)
      |> keyword_rename(:query, :query_path)
    opts = opts |> Keyword.merge(upstream)
    Logger.info("ReverseProxy opts: #{inspect opts}")
    callback = fn conn ->
      runner = Application.get_env(:reverse_proxy, :runner, ReverseProxy.Runner)
      runner.retreive(conn, opts)
    end

    if Application.get_env(:reverse_proxy, :cache, false) do
      cacher = Application.get_env(:reverse_proxy, :cacher, ReverseProxy.Cache)
      cacher.serve(conn, callback)
    else
      callback.(conn)
    end
  end

  defp keyword_rename(keywords, old_key, new_key), do: keywords
    |> Keyword.put(new_key, keywords[old_key])
    |> Keyword.delete(old_key)

  @spec start(term, term) :: {:error, term}
                           | {:ok, pid}
                           | {:ok, pid, term}
  def start(_type, _args) do
    import Supervisor.Spec, warn: false

    children = [
    ]

    opts = [strategy: :one_for_one, name: ReverseProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
