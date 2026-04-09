"""
Applet: TV Shows Next Ep
Summary: Displays TV show air dates
Description: Displays the next episode air dates of two shows using tvdb. **Shoutout to Anime Next Ep by brianmakesthings**
Author: vsocrates
"""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("humanize.star", "humanize")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

TVDB_URL = "https://api4.thetvdb.com/v4/"

# Typeahead handlers inside schema.Generated are looked up as "{field_id}$search"
# which requires a "$" in the function name — impossible in Starlark. So we use
# top-level Typeahead fields and bridge the auth token via cache. main() populates
# the cache; search() reads from it. First-time flow: enter API key → save → search.
AUTH_CACHE_KEY = "tv_shows_next_ep_auth_token"

def main(config):
    api_key = config.get("api_key")
    if not api_key:
        return render.Root(
            child = render.WrappedText("Add your TVDB API key in settings", color = "#FF6600", font = "tom-thumb"),
        )

    auth_token = get_auth_token(api_key)
    if not auth_token:
        return render.Root(
            child = render.WrappedText("TVDB auth failed — check your API key", color = "#FF0000", font = "tom-thumb"),
        )

    # Populate cache so the Typeahead search handler can authenticate.
    cache.set(AUTH_CACHE_KEY, auth_token, ttl_seconds = 1728000)

    show_1_id = get_show_id_from_config(config, "tv_show_1")
    show_2_id = get_show_id_from_config(config, "tv_show_2")

    if not show_1_id:
        return render.Root(
            child = render.WrappedText("Select at least one TV show in settings", color = "#FF6600", font = "tom-thumb"),
        )

    show_rows = [
        render.Row(
            children = [
                render.Text(content = "Time to New Ep", font = "tb-8", color = "#FF6600"),
            ],
        ),
    ]

    show_rows.append(render_show_row(show_1_id, auth_token, pad = (0, 1, 0, 1) if show_2_id else (0, 1, 0, 0)))

    if show_2_id:
        show_rows.append(render_show_row(show_2_id, auth_token, pad = (0, 1, 0, 0)))

    return render.Root(
        child = render.Column(children = show_rows),
    )

def get_show_id_from_config(config, key):
    value = config.get(key)
    if value == None:
        return None

    # schema.Typeahead returns a JSON string like {"display": "...", "value": "123"}
    if value.startswith("{"):
        show_id = json.decode(value).get("value")
        if not show_id:
            return None
        return show_id
    return value

def render_show_row(series_id, auth_token, pad):
    artwork = render_cover(series_id, auth_token = auth_token)
    desc = render_description(series_id, auth_token = auth_token)
    return render.Padding(
        child = render.Row(
            children = [
                render.Row(
                    children = [
                        render.Padding(child = artwork, pad = (0, 0, 2, 0)),
                        render.Marquee(desc, width = 50, scroll_direction = "horizontal"),
                    ],
                    main_align = "center",
                    cross_align = "center",
                ),
            ],
            main_align = "left",
            cross_align = "left",
            expanded = True,
        ),
        pad = pad,
    )

def render_description(series_id, auth_token):
    name = fetch_name(series_id, auth_token)
    nextairdate = fetch_nextairdate(series_id, auth_token)
    return render.Text(
        content = name + ": " + nextairdate,
        font = "tom-thumb",
        color = "#D9FF00",
    )

def fetch_name(series_id, auth_token):
    resp = http.get(
        TVDB_URL + "series/" + series_id,
        headers = {"Authorization": "Bearer " + auth_token},
        ttl_seconds = 3600,
    )
    if resp.status_code != 200:
        return "Unknown"
    data = resp.json().get("data")
    if not data:
        return "Unknown"
    return data.get("name", "Unknown")

def fetch_nextairdate(series_id, auth_token):
    resp = http.get(
        TVDB_URL + "series/" + series_id + "/nextAired",
        headers = {"Authorization": "Bearer " + auth_token},
        ttl_seconds = 3600,
    )
    if resp.status_code != 200:
        return "TBA"

    data = resp.json().get("data")
    if not data:
        return "TBA"

    next_aired = data.get("nextAired")
    if not next_aired:
        # Show has no upcoming episode — check if it ended or is just on hiatus
        status = data.get("status") or {}
        if status.get("name") == "Ended":
            return "Ended"
        return "TBA"

    # Slice to date portion only — TVDB may return a full datetime like
    # "2024-01-15T22:00:00Z" which would crash time.parse_time with format "2006-01-02"
    parsed = time.parse_time(next_aired[:10], format = "2006-01-02")
    humanized = humanize.time(parsed)
    return humanized.split("from now")[0]

def fetch_image(series_id, auth_token):
    # Type 5 = clearlogo; falls back to None if unavailable
    artwork_resp = http.get(
        TVDB_URL + "series/" + series_id + "/artworks",
        headers = {"Authorization": "Bearer " + auth_token},
        params = {"type": "5", "lang": "eng"},
        ttl_seconds = 86400,
    )
    if artwork_resp.status_code != 200:
        return None

    data = artwork_resp.json().get("data")
    if not data:
        return None

    artworks = data.get("artworks")
    if not artworks or len(artworks) == 0:
        return None

    image_url = artworks[0].get("image")
    if not image_url:
        return None

    img_resp = http.get(image_url, ttl_seconds = 86400)
    if img_resp.status_code != 200:
        return None

    body = img_resp.body()
    if not body:
        return None
    return body

def render_cover(series_id, auth_token):
    cover_image = fetch_image(series_id, auth_token)
    if cover_image == None:
        # Placeholder box so row layout is preserved when no art is available
        return render.Box(width = 10, height = 14, color = "#333333")
    return render.Padding(
        child = render.Image(width = 10, src = cover_image),
        pad = (0, 0, 0, 0),
    )

def get_auth_token(api_key):
    if not api_key:
        return None
    res = http.post(
        TVDB_URL + "login",
        json_body = {"apikey": api_key},
        ttl_seconds = 1728000,
    )
    if res.status_code != 200:
        return None
    data = res.json().get("data")
    if not data:
        return None
    return data.get("token")

def search(pattern):
    if not pattern:
        return []

    auth_token = cache.get(AUTH_CACHE_KEY)
    if not auth_token:
        return []

    resp = http.get(
        TVDB_URL + "search",
        headers = {
            "Authorization": "Bearer " + auth_token,
            "Accept": "application/json",
        },
        params = {
            "query": pattern,
            "type": "series",
            "lang": "eng",
            "limit": "10",
        },
    )
    if resp.status_code != 200:
        return []

    data = resp.json().get("data")
    if not data:
        return []

    options = []
    for item in data:
        name = item.get("name")
        # Prefer tvdb_id (always a plain series ID); fall back to id
        tvdb_id = item.get("tvdb_id") or str(item.get("id", ""))
        if name and tvdb_id:
            options.append(schema.Option(display = name, value = tvdb_id))
    return options

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "api_key",
                name = "TVDB API Key",
                desc = "Create a free API key at tvdb.com. Save this first — the show search below uses it.",
                icon = "key",
            ),
            schema.Typeahead(
                id = "tv_show_1",
                name = "TV Show #1",
                desc = "First show to display",
                icon = "tv",
                handler = search,
            ),
            schema.Typeahead(
                id = "tv_show_2",
                name = "TV Show #2 (optional)",
                desc = "Second show to display. Leave blank to show only one.",
                icon = "tv",
                handler = search,
            ),
        ],
    )
