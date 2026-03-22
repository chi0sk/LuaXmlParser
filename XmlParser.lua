--// @ chi0sk / sam
-- handles parsing, serializing, and querying.
-- everything leans on native c-extension calls (string.find, string.gmatch) --
-- string concatenation in tight loops creates excessive gc pressure in luau, don't do it.

local xml = {}

export type XmlAttributes = { [string]: string }
export type XmlNode = {
	Tag: string,
	Attributes: XmlAttributes,
	Children: { XmlNode },
	Text: string?,
}

-- node metatable for oop methods
local node_mt = {}
node_mt.__index = node_mt

-- named xml/html entities
local entities = {
	["&amp;"] = "&",
	["&lt;"] = "<",
	["&gt;"] = ">",
	["&quot;"] = '"',
	["&apos;"] = "'",
}

-- two-pass greedy trim. way faster than ^%s*(.-)%s*$ because lazy patterns
-- backtrack on every single character -- don't use lazy if you can avoid it
local function trim(s: string): string
	s = string.match(s, "^%s*(.*%S)") or ""
	return s
end

-- unescape named (&amp;), decimal numeric (&#65;), and hex numeric (&#x41;) entities
-- the early exit on & is intentional -- most strings won't have entities at all
local function unescape(str: string): string
	if not string.find(str, "&", 1, true) then return str end
	str = string.gsub(str, "&[%a][%w]*;", entities)
	str = string.gsub(str, "&#(%d+);", function(n)
		return utf8.char(tonumber(n))
	end)
	str = string.gsub(str, "&#x(%x+);", function(h)
		return utf8.char(tonumber(h, 16))
	end)
	return str
end

-- escape a string safely for xml output.
-- the outer () truncates string.gsub to one return value -- gsub returns (string, count)
-- and if you pass that directly into table.insert, the count leaks in as a position arg.
local function escape(str: string): string
	return (string.gsub(str, "[&<>\"']", function(c)
		if c == "&" then return "&amp;" end
		if c == "<" then return "&lt;" end
		if c == ">" then return "&gt;" end
		if c == '"' then return "&quot;" end
		if c == "'" then return "&apos;" end
	end))
end

-- new node, metatable attached
local function create_node(tag: string, attrs: XmlAttributes?, children: { XmlNode }?, text: string?): XmlNode
	local node = {
		Tag = tag,
		Attributes = attrs or {},
		Children = children or {},
		Text = text,
	}
	setmetatable(node, node_mt)
	return node
end

-- parse an xml string into a node tree.
-- returns (node, nil) on success or (nil, errmsg) on failure -- wrap in pcall if you're paranoid
function xml.parse(xml_str: string): (XmlNode?, string?)
	if type(xml_str) ~= "string" then
		return nil, "pass a string bro"
	end

	local pos = 1
	local len = #xml_str

	local root = create_node("DOCUMENT_ROOT")
	local stack = { root }
	local top = 1

	while pos <= len do
		-- jump to the next tag opener
		local start_tag = string.find(xml_str, "<", pos, true)

		if not start_tag then
			-- no more tags, grab whatever text is left
			local leftover = string.sub(xml_str, pos)
			local clean = trim(leftover)
			if clean ~= "" then
				stack[top].Text = (stack[top].Text or "") .. unescape(clean)
			end
			break
		end

		-- text sitting between the previous tag close and this opener
		if start_tag > pos then
			local text = string.sub(xml_str, pos, start_tag - 1)
			local clean = trim(text)
			if clean ~= "" then
				stack[top].Text = (stack[top].Text or "") .. unescape(clean)
			end
		end

		local next_char = string.sub(xml_str, start_tag + 1, start_tag + 1)

		if next_char == "/" then
			-- closing tag </foo>
			local close_end = string.find(xml_str, ">", start_tag + 2, true)
			if not close_end then
				return nil, string.format("missing '>' for closing tag at position %d", start_tag)
			end

			local tag_name = trim(string.sub(xml_str, start_tag + 2, close_end - 1))

			-- stray closing tag with nothing on the stack to match it
			if top <= 1 then
				return nil, string.format("unexpected closing tag </%s> at position %d", tag_name, start_tag)
			end

			if stack[top].Tag ~= tag_name then
				return nil,
					string.format(
						"mismatched tag at position %d: expected </%s>, got </%s>",
						start_tag,
						stack[top].Tag,
						tag_name
					)
			end

			top -= 1
			pos = close_end + 1

		elseif next_char == "!" or next_char == "?" then
			-- comments, cdata, processing instructions, doctype -- skip or extract
			if string.sub(xml_str, start_tag, start_tag + 3) == "<!--" then
				-- <!-- comment -->
				local comment_end = string.find(xml_str, "-->", start_tag + 4, true)
				pos = (comment_end or len) + 3
			elseif string.sub(xml_str, start_tag, start_tag + 8) == "<![CDATA[" then
				-- cdata is stored verbatim, entity escaping doesn't apply inside it
				local cdata_end = string.find(xml_str, "]]>", start_tag + 9, true)
				if cdata_end then
					local cdata = string.sub(xml_str, start_tag + 9, cdata_end - 1)
					stack[top].Text = (stack[top].Text or "") .. cdata
					pos = cdata_end + 3
				else
					pos = len + 1
				end
			else
				-- <?xml version="1.0"?> or <!DOCTYPE ...> etc, just skip past it
				local decl_end = string.find(xml_str, ">", start_tag + 2, true)
				pos = (decl_end or len) + 1
			end
		else
			-- opening tag <foo attr="val"> or self-closing <foo />
			local tag_content_end = string.find(xml_str, ">", start_tag + 1, true)
			if not tag_content_end then
				return nil, string.format("missing '>' for opening tag at position %d", start_tag)
			end

			local tag_content = string.sub(xml_str, start_tag + 1, tag_content_end - 1)

			-- trailing slash check, handles <br /> (space before /) correctly
			local is_self_closing = string.match(tag_content, "/%s*$") ~= nil
			if is_self_closing then
				tag_content = string.match(tag_content, "^(.-)%s*/$") or tag_content
			end

			local space_idx = string.find(tag_content, "%s")
			local tag_name = tag_content
			local attr_str = ""

			if space_idx then
				tag_name = string.sub(tag_content, 1, space_idx - 1)
				attr_str = string.sub(tag_content, space_idx + 1)
			end

			if tag_name == "" then
				return nil, string.format("empty tag name at position %d", start_tag)
			end

			local new_node = create_node(tag_name)

			-- handles both "value" and 'value' quoting
			if attr_str ~= "" then
				for attr_name, _, attr_val in string.gmatch(attr_str, "([%w%-_:]+)%s*=%s*([\"'])(.-)%2") do
					new_node.Attributes[attr_name] = unescape(attr_val)
				end
			end

			table.insert(stack[top].Children, new_node)

			if not is_self_closing then
				top += 1
				stack[top] = new_node
			end

			pos = tag_content_end + 1
		end
	end

	if top ~= 1 then
		return nil, string.format("unclosed tag: <%s>", stack[top].Tag)
	end

	return root.Children[1], nil
end

-- serialize a node tree back to an xml string.
-- indent gets passed down pre-built so we never call string.rep per node.
-- table.concat is mandatory here -- .. in a recursive tree degrades toward o(n²)
-- allocations because strings are immutable and every concat copies both sides.
function xml.serialize(node: XmlNode, pretty: boolean?, indent: string?): string
	pretty = pretty or false
	indent = indent or ""
	local nl = pretty and "\n" or ""

	local buf = {}

	table.insert(buf, indent .. "<" .. node.Tag)

	-- sort keys so two serializations of the same node always produce the same string.
	-- without this pairs() order is undefined and diffs/hashes break.
	local attr_keys = {}
	for k in pairs(node.Attributes) do
		table.insert(attr_keys, k)
	end
	table.sort(attr_keys)

	for _, k in ipairs(attr_keys) do
		table.insert(buf, string.format(' %s="%s"', k, escape(tostring(node.Attributes[k]))))
	end

	local children_count = #node.Children
	local has_text = node.Text and node.Text ~= ""

	if children_count == 0 and not has_text then
		table.insert(buf, "/>" .. nl)
	else
		table.insert(buf, ">")

		if has_text then
			table.insert(buf, escape(node.Text))
		elseif pretty and children_count > 0 then
			table.insert(buf, "\n")
		end

		-- build child indent once, pass it down, not recomputed per child
		local child_indent = pretty and (indent .. "  ") or ""
		for _, child in ipairs(node.Children) do
			table.insert(buf, xml.serialize(child, pretty, child_indent))
		end

		if pretty and children_count > 0 and not has_text then
			table.insert(buf, indent)
		end

		table.insert(buf, "</" .. node.Tag .. ">" .. nl)
	end

	return table.concat(buf)
end

-- print(node) gives you the xml string instead of a useless table address
node_mt.__tostring = function(self)
	return xml.serialize(self)
end

-- // node methods for traversal and mutation

-- first direct child matching the tag, or nil
function node_mt:FindFirstChild(tag: string): XmlNode?
	for _, child in ipairs(self.Children) do
		if child.Tag == tag then return child end
	end
	return nil
end

-- all direct children with this tag
function node_mt:GetChildren(tag: string): { XmlNode }
	local res = {}
	for _, child in ipairs(self.Children) do
		if child.Tag == tag then table.insert(res, child) end
	end
	return res
end

-- xpath-ish path query. doesn't implement the full spec but covers basically everything you'd need:
--   "player/inventory/item"       direct child traversal
--   "//item"                      recursive descendant search
--   "item[@id='sword']"           attribute predicate
-- combinable: "player//item[@id='sword']"
function node_mt:Query(path: string): { XmlNode }
	local results = {}

	local function search(current: XmlNode, parts: { string }, depth: number)
		if depth > #parts then
			table.insert(results, current)
			return
		end

		local target = parts[depth]
		local is_recursive = string.sub(target, 1, 2) == "//"
		local match_target = is_recursive and string.sub(target, 3) or target

		-- pull apart tag[@attr='val'] if there's a predicate
		local tag_part, attr_key, attr_val =
			string.match(match_target, "^(.-)%[@([%w%-_:]+)=[\"'](.-)['\"]]$")

		local actual_tag: string
		local predicate: { key: string, val: string }?

		if tag_part then
			actual_tag = tag_part
			predicate = { key = attr_key, val = attr_val }
		else
			actual_tag = match_target
		end

		local function matches(n: XmlNode): boolean
			if n.Tag ~= actual_tag then return false end
			if predicate and n.Attributes[predicate.key] ~= predicate.val then return false end
			return true
		end

		if is_recursive then
			local function walk(n: XmlNode)
				if matches(n) then search(n, parts, depth + 1) end
				for _, c in ipairs(n.Children) do walk(c) end
			end
			for _, c in ipairs(current.Children) do walk(c) end
		else
			for _, c in ipairs(current.Children) do
				if matches(c) then search(c, parts, depth + 1) end
			end
		end
	end

	-- split on / while keeping // markers attached to the segment they belong to.
	-- "//target" must produce ["//target"], not ["//", "target"] --
	-- if "//" ends up as its own part, string.sub(target, 3) gives "" and nothing ever matches.
	local raw = {}
	for part in string.gmatch(string.gsub(path, "//", "/\0/"), "[^/]+") do
		part = string.gsub(part, "\0", "//")
		if part ~= "." then table.insert(raw, part) end
	end
	local parts = {}
	local i = 1
	while i <= #raw do
		if raw[i] == "//" and raw[i + 1] then
			-- reattach the marker to the next segment
			table.insert(parts, "//" .. raw[i + 1])
			i += 2
		else
			table.insert(parts, raw[i])
			i += 1
		end
	end

	search(self, parts, 1)
	return results
end

-- first match or nil
function node_mt:QuerySingle(path: string): XmlNode?
	return self:Query(path)[1]
end

-- attribute getters/setters
function node_mt:GetAttribute(key: string): string?
	return self.Attributes[key]
end

function node_mt:SetAttribute(key: string, val: any)
	self.Attributes[key] = tostring(val)
end

function node_mt:RemoveAttribute(key: string)
	self.Attributes[key] = nil
end

-- depth-first walk over every descendant, callback gets each node
function node_mt:WalkDescendants(callback: (XmlNode) -> ())
	for _, child in ipairs(self.Children) do
		callback(child)
		child:WalkDescendants(callback)
	end
end

-- append a new child and return it
function node_mt:AddChild(tag: string, attrs: XmlAttributes?, text: string?): XmlNode
	local child = create_node(tag, attrs, nil, text)
	table.insert(self.Children, child)
	return child
end

-- remove by index or direct node reference
function node_mt:RemoveChild(target: number | XmlNode)
	if type(target) == "number" then
		table.remove(self.Children, target)
	else
		for i, child in ipairs(self.Children) do
			if child == target then
				table.remove(self.Children, i)
				break
			end
		end
	end
end

-- swap out the text content on a node
function node_mt:SetText(text: string)
	self.Text = text
end

-- spawn a root node if you're building xml from scratch instead of parsing
function xml.create(tag: string, attrs: XmlAttributes?, text: string?): XmlNode
	return create_node(tag, attrs, nil, text)
end

return xml
