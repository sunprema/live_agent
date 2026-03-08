defmodule LiveAgent.Panel do
  @moduledoc false

  def standalone_html do
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>LiveAgent</title>
      <link rel="stylesheet" href="/live_agent/css">
      <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
        html, body { height: 100%; background: #1e1e2e; overflow: hidden; }
        #la-root { height: 100%; }
      </style>
    </head>
    <body>
      <div id="la-root" data-la-standalone="true"></div>
      <script src="/live_agent/js"></script>
    </body>
    </html>
    """
  end
end
