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

  def retreive(conn, options, client \\ HTTPotion) do
    {method, url, body, headers} = prepare_request(conn, options)
    Logger.debug("Proxying to #{url}. Method: #{method}, body: #{body}, headers: #{inspect headers}")
    headers = Enum.map(headers, fn {key, value} -> {:"#{key}", value} end)
    Logger.debug("Request headers: #{inspect headers}")
    client.request(method, url, body, headers, [timeout: :infinity, stream_to: self()])
    stream_response(conn)
  end

  @spec stream_response(Conn.t) :: Conn.t
  defp stream_response(conn) do
    receive do
      # %HTTPotion.AsyncStatus{code: code} ->
      #   Logger.debug("Response HTTPotion.AsyncStatus received for request to #{conn.request_path}: #{code}")
      #   conn
      #     |> Conn.put_status(code)
      #     |> stream_response
      %HTTPotion.Response{} ->
        Logger.debug("HTTPOTION RESPONSE")
      %HTTPotion.ErrorResponse{message: message} ->
        Logger.warn("HTTPotion.ErrorResponse: #{message}")
      %HTTPotion.AsyncResponse{} ->
        Logger.debug("HTTPotion.AsyncResponse")
        stream_response(conn)
      %HTTPotion.AsyncHeaders{status_code: status_code, headers: headers} ->
        Logger.debug("Response HTTPotion.AsyncHeaders with code #{inspect status_code} received for request to #{conn.request_path}: #{inspect headers}")
        conn
          # |> Conn.put_status(status_code)
          |> put_resp_headers(Map.to_list(headers.hdrs))
          # |> Conn.put_resp_header("transfer-encoding", "chunked")
          # |> Conn.put_resp_header("connection", "close")
          |> Conn.send_chunked(status_code)
          |> stream_response
      %HTTPotion.AsyncChunk{chunk: chunk} ->
        Logger.debug("Response HTTPotion.AsyncChunk with length #{byte_size(chunk)} received for request to #{conn.request_path}")
        case Conn.chunk(conn, chunk) do
          {:ok, conn} ->
            stream_response(conn)
          {:error, :closed} ->
            Logger.info("Client closed before chunk streaming ended")
            conn
        end
      %HTTPotion.AsyncEnd{} ->
        Logger.debug("Response HTTPotion.AsyncEnd received for request to #{conn.request_path}. Sending terminating chunk.")
        Logger.debug("Response headers: #{inspect conn.resp_headers}")
        # :cowboy_req.stream_body(<<>>, :fin, elem(conn.adapter, 1))
        conn
    end
  end

  @spec prepare_request(String.t, Conn.t) :: {Atom.t,
                                                  String.t,
                                                  String.t,
                                                  [{String.t, String.t}]}

  defp prepare_url(conn, overrides) do
    keys = [:scheme, :host, :port, :query_string]
    x = conn
      |> Map.to_list
      |> Enum.filter(fn {key, _} -> key in keys end)
      |> Keyword.merge(Enum.filter(overrides, fn {_, val} -> !!val end))
    request_path = Enum.join(conn.path_info, "/")
    request_path = case request_path do
      "" -> request_path
      path -> "/" <> path
    end
    url = "#{x[:scheme]}://#{x[:host]}:#{x[:port]}#{overrides[:request_path]}#{request_path}"
    case x[:query_string] do
      "" -> url
      query_string -> url <> "?" <> query_string
    end
  end

  defp prepare_request(conn, options) do
    conn = conn
            |> Conn.put_req_header(
              "x-forwarded-for",
              conn.remote_ip |> :inet.ntoa |> to_string
            )
            |> Conn.delete_req_header(
              "transfer-encoding"
            )
            |> Conn.delete_req_header(
              "host"
            )
    method = conn.method |> String.downcase |> String.to_atom
    url = prepare_url(conn, options)
    headers = conn.req_headers
    # headers = if options[:preserve_host_header], do: headers, else: List.keyreplace(headers, "host", 0, {"host", options[:host]})
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

  @spec put_resp_headers(Conn.t, [{String.t, String.t}]) :: Conn.t
  defp put_resp_headers(conn, []), do: conn
  defp put_resp_headers(conn, [{header, value} | rest]) do
    conn
      |> Conn.put_resp_header(header |> String.downcase, value)
      |> put_resp_headers(rest)
  end

end
