defmodule ReverseProxy.Runner do
  @moduledoc """
  Retreives content from an upstream.
  """
  require Logger
  alias Plug.Conn

  @typedoc "Representation of an upstream service."
  @type upstream :: [String.t] | {Atom.t, Keyword.t}

  @spec retreive(Conn.t, upstream) :: Conn.t
  def retreive(conn, upstream)
  def retreive(conn, {plug, opts}) when plug |> is_atom do
    options = plug.init(opts)
    plug.call(conn, options)
  end

  @spec retreive(Conn.t, upstream, Atom.t) :: Conn.t
  def retreive(conn, servers, client \\ HTTPoison) do
    server = upstream_select(servers)
    {method, url, body, headers} = prepare_request(server, conn)

    client.request(method, url, body, headers, [timeout: :infinity, recv_timeout: :infinity, stream_to: self()])
    stream_response(conn)
  end

  @spec stream_response(Conn.t) :: Conn.t
  defp stream_response(conn) do
    receive do
      %HTTPoison.AsyncStatus{code: code} ->
        conn
          |> Conn.put_status(code)
          |> stream_response
      %HTTPoison.AsyncHeaders{headers: headers} ->
        conn
          |> put_resp_headers(headers)
          |> Conn.send_chunked(conn.status)
          |> stream_response
      %HTTPoison.AsyncChunk{chunk: chunk} ->
        case Conn.chunk(conn, chunk) do
          {:ok, conn} ->
            stream_response(conn)
          {:error, :closed} ->
            Logger.info("Client closed before chunk streaming ended")
            conn
        end
      %HTTPoison.AsyncEnd{} ->
        conn
    end
  end

  @spec prepare_request(String.t, Conn.t) :: {Atom.t,
                                                  String.t,
                                                  String.t,
                                                  [{String.t, String.t}]}
  defp prepare_request(server, conn) do
    conn = conn
            |> Conn.put_req_header(
              "x-forwarded-for",
              conn.remote_ip |> :inet.ntoa |> to_string
            )
            |> Conn.delete_req_header(
              "transfer-encoding"
            )
    method = conn.method |> String.downcase |> String.to_atom
    url = "#{prepare_server(conn.scheme, server)}#{conn.request_path}?#{conn.query_string}"
    headers = conn.req_headers
    body = case Conn.read_body(conn) do
      {:ok, body, _conn} ->
        body
      {:more, body, conn} ->
        {:stream,
          Stream.resource(
            fn -> {body, conn} end,
            fn
              {body, conn} ->
                {[body], conn}
              nil ->
                {:halt, nil}
              conn ->
                case Conn.read_body(conn) do
                  {:ok, body, _conn} ->
                    {[body], nil}
                  {:more, body, conn} ->
                    {[body], conn}
                end
            end,
            fn _ -> nil end
          )
        }
    end

    {method, url, body, headers}
  end

  @spec prepare_server(String.t, String.t) :: String.t
  defp prepare_server(scheme, server)
  defp prepare_server(_, "http://" <> _ = server), do: server
  defp prepare_server(_, "https://" <> _ = server), do: server
  defp prepare_server(scheme, server) do
    "#{scheme}://#{server}"
  end

  @spec put_resp_headers(Conn.t, [{String.t, String.t}]) :: Conn.t
  defp put_resp_headers(conn, []), do: conn
  defp put_resp_headers(conn, [{header, value} | rest]) do
    conn
      |> Conn.put_resp_header(header |> String.downcase, value)
      |> put_resp_headers(rest)
  end

  defp upstream_select(servers) do
    servers |> hd
  end
end
