# xmlparser.lua

xml parser, serializer, and query lib for luau. built for roblox but works anywhere luau runs.

```lua
local xml = require(path.to.xml)

local node = xml.parse([[
    <player id="1" name="sam">
        <inventory>
            <item id="sword" count="3"/>
            <item id="shield" count="1"/>
        </inventory>
    </player>
]])

node:GetAttribute("name")                              --> "sam"
node:QuerySingle("inventory/item"):GetAttribute("id")  --> "sword"
node:Query('inventory/item[@id="shield"]')[1]          --> the shield node
```

---

## install

copy `xmlparser.lua` into your project. no dependencies.

---

## parsing

```lua
local node, err = xml.parse(str)
if not node then
    warn(err)
end
```

returns `(XmlNode, nil)` on success or `(nil, errmsg)` on failure. safe to wrap in `pcall`.

supports:
- standard tags, attributes, text content
- self-closing tags `<br/>` and `<br />`
- single and double quoted attribute values
- named entities `&amp;` `&lt;` `&gt;` `&quot;` `&apos;`
- decimal numeric references `&#65;`
- hex numeric references `&#x41;`
- comments `<!-- ... -->` (skipped)
- cdata sections `<![CDATA[...]]>` (stored verbatim)
- xml declarations and doctypes (skipped)

---

## querying

```lua
-- direct child path
node:Query("inventory/item")

-- recursive descendant search
node:Query("//item")

-- attribute predicate
node:Query("item[@id='sword']")

-- combined
node:Query("inventory//item[@id='sword']")

-- first match or nil
node:QuerySingle("inventory/item")

-- direct children only
node:FindFirstChild("inventory")
node:GetChildren("item")
```

---

## serializing

```lua
-- compact
xml.serialize(node)

-- pretty printed
xml.serialize(node, true)
```

attributes are sorted alphabetically so the output is always the same for the same node. `tostring(node)` works too.

---

## building without parsing

```lua
local root = xml.create("player", { id = "1", name = "sam" })
local inv = root:AddChild("inventory")
inv:AddChild("item", { id = "sword", count = "3" })

xml.serialize(root, true)
-- <player id="1" name="sam">
--   <inventory>
--     <item count="3" id="sword"/>
--   </inventory>
-- </player>
```

---

## api

| method | description |
|---|---|
| `node:FindFirstChild(tag)` | first direct child with this tag, or nil |
| `node:GetChildren(tag)` | all direct children with this tag |
| `node:Query(path)` | returns table of all matches |
| `node:QuerySingle(path)` | first match or nil |
| `node:AddChild(tag, attrs?, text?)` | append a child, returns the new node |
| `node:RemoveChild(index or node)` | remove by position or reference |
| `node:GetAttribute(key)` | attribute value or nil |
| `node:SetAttribute(key, val)` | set attribute, coerces to string |
| `node:RemoveAttribute(key)` | delete an attribute |
| `node:SetText(text)` | set text content |
| `node:WalkDescendants(fn)` | depth-first walk over every descendant |

---

## types

```lua
type XmlAttributes = { [string]: string }

type XmlNode = {
    Tag: string,
    Attributes: XmlAttributes,
    Children: { XmlNode },
    Text: string?,
}
```

---

## known limitation

closing detection for `<?...?>` and `<!...>` uses a plain `string.find` for `>`. a `>` inside an attribute value in a declaration like `<?xml note="a>b"?>` would close early. this basically never comes up in practice.
