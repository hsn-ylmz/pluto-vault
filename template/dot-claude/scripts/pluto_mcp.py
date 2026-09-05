#!{{PY}}
from mcp.server.mcpserver import MCPServer
from pathlib import Path
from datetime import date
import pluto_search, pluto_index

VAULT = Path(__file__).resolve().parents[2]
mcp = MCPServer("pluto")  # mcp 2.x: FastMCP was renamed MCPServer

@mcp.tool()
def search_memory(query: str, k: int = 5) -> list:
    """Semantic search over the vault. Returns matching chunks with their source path."""
    return pluto_search.search(query, k)

@mcp.tool()
def append_daily(text: str) -> str:
    """Append a line to today's daily log. Append-only; never rewrites past days."""
    f = VAULT / "daily" / f"{date.today()}.md"
    f.parent.mkdir(exist_ok=True)
    if not f.exists():
        f.write_text(f"# {date.today()}\n\n")
    with f.open("a") as fh:
        fh.write(f"- {text}\n")
    return str(f.relative_to(VAULT))

@mcp.tool()
def write_note(slug: str, content: str) -> str:
    """Create or overwrite notes/<slug>.md with durable knowledge."""
    f = VAULT / "notes" / f"{slug}.md"
    f.parent.mkdir(exist_ok=True)
    f.write_text(content)
    return str(f.relative_to(VAULT))

@mcp.tool()
def reindex() -> str:
    """Re-run the embedding index over the vault."""
    pluto_index.main()
    return "reindexed"

if __name__ == "__main__":
    mcp.run()
