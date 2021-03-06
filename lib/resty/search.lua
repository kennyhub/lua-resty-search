-- Copyright (C) Anton heryanto.

local rrandom = require "resty.random"
local rstring = require "resty.string"
local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end


local setmetatable = setmetatable
local lower = string.lower
local max = math.max
local log = math.log
local unpack = unpack
local match = ngx.re.match
local gsub = ngx.re.gsub
local null = ngx.null
local type = type
local find = string.find
local sub = string.sub


local function split(self, delimiter, limit)
    if not self or type(self) ~= "string" then return end

    local length = #self
    if length == 1 then return {self} end

    local result = limit and new_tab(limit, 0) or {}
    local index = 0
    local n = 1

    while true do
        if limit and n > limit then break end
         -- find the next d in the string
        local pos = find(self,delimiter, index,true)
        if pos ~= nil then -- if "not not" found then..
            result[n] = sub(self,index, pos - 1) -- Save it in our array.
            -- save just after where we found it for searching next time.
            index = pos + 1
        else
            result[n] = sub(self,index) -- Save what's left in our array.
            break -- Break at end, as it should be, according to the lua manual.
        end
        n = n + 1
    end

    return result, n
end


-- stop words pulled from the below url
-- http://www.textfixer.com/resources/common-english-words.txt
local WORDS = [['a,able,about,across,after,all,almost,also,am,among,an,and,any,
are,as,at,be,because,been,but,by,can,cannot,could,dear,did,do,does,either,else,
ever,every,for,from,get,got,had,has,have,he,her,hers,him,his,how,however,i,if,
in,into,is,it,its,just,least,let,like,likely,may,me,might,most,must,my,neither,
no,nor,not,of,off,often,on,only,or,other,our,own,rather,said,say,says,she,
should,since,so,some,than,that,the,their,them,then,there,these,they,this,tis,
to,too,twas,us,wants,was,we,were,what,when,where,which,while,who,whom,why,will,
with,would,yet,you,your']]
local common_words = split(WORDS, ",")
local nword = #common_words

local function add_words(words)
    local n = max(words and #words, 0)

    local stop_words = new_tab(0, nword + n)
    for i = 1, nword do
        stop_words[common_words[i]] = true
    end

    for i = 1, n do
        stop_words[words[i]] = true
    end

    return stop_words
end

local _M = new_tab(0,4)
local mt = { __index = _M }

-- FIXME init redis outside new
function _M.new(self, prefix, words)
    -- All of our index keys are going to be prefixed with the provided
    -- prefix string.  This will allow multiple independent indexes to
    -- coexist in the same Redis db.
    prefix = prefix and lower(prefix) ..":" or ""
    return setmetatable({
        stop_words = add_words(words),  -- add another common words
        index = prefix .. 'index',
        prefix = prefix,
        redis = nil
    }, mt)
end


function _M.connect(self, redis)
    self.redis = redis
end

-- Very simple word-based parser.  We skip stop words and single character words.
local function get_index_keys(self, content)
    -- remove non alphanumeric character
    local stop_words = self.stop_words
    local raw = gsub(lower(content), "[^a-z0-9' ]", " ", "jo")
    local raws = split(raw, " ")
    -- strip multi occurance of '
    local j = 0
    local words = {}
    for i = 1, #raws do
        local w = split(raws[i], "'")[1]
        if not stop_words[w] and #w > 1 then
            j = j + 1
            words[j] = w
        end
    end

    return words, j
end

-- Calculated the TF portion of TF/IDF
local function get_index_scores(self, content)
    local words, wordcount = get_index_keys(self, content)
    local j = 1
    local keys = {}
    local counts = {}
    for i=1,wordcount do
        local w = words[i]
        counts[w] = (counts[w] or 0.0) + 1.0
        if counts[w] then
            keys[j] = w
            j = j + 1
        end
    end

    local ncount = #keys
    local tf = new_tab(0,ncount)
    for i=1,ncount do
        local k = keys[i]
        tf[k] = counts[k]/wordcount
    end

    return keys, ncount, tf
end

local function empty(v)
    return not v or v == null or v == '' or v == ' '
end

function _M.add_indexed_item(self, id, content)
    if empty(content) then return 0 end

    local r = self.redis
    local prefix = self.prefix
    local keys, n, tf = get_index_scores(self, content)
    r:init_pipeline(n + 1)
    r:sadd(self.index, id)
    for i = 1, n do
        local k = keys[i]
        r:zadd(prefix .. k, tf[k], id)
    end
    r:commit_pipeline()
    return n
end

function _M.remove_indexed_item(self, id, content)
    if empty(content) then return 0 end

    local r = self.redis
    local prefix = self.prefix
    local keys, n = get_index_scores(self, content)
    r:init_pipeline(n + 1)
    r:srem(self.index, id)
    for i = 1, n do
        local k = keys[i]
        r:zrem(prefix .. k, id)
    end
    r:commit_pipeline()
    return n
end

function _M.query(self, q, offset, count)
    offset = offset or 0
    count = count or 10
    -- Get our search terms just like we did earlier...
    local r = self.redis
    local prefix = self.prefix
    local words, n = get_index_keys(self, q)
    if n == 0 then return {}, 0 end

    local total_docs = max(r:scard(self.index), 1)
    local keys = new_tab(n, 0)

    -- Get our document frequency values...
    r:init_pipeline(n)
    for i = 1, n do
        local key = prefix .. words[i]
        keys[i] = key
        r:zcard(key)
    end
    local sizes = r:commit_pipeline()

    -- Calculate the inverse document frequencies..
    local idfs = new_tab(n, 0)
    local nsize = 0
    for i=1,n do
        local size = sizes[i]
        if size > 0 then nsize = nsize + 1 end
        -- math.log(value,base) = math.log(value) / math.log(base)
        idfs[i] = size == 0 and 0 or max(log(total_docs/size) / log(2), 0)
    end

    if nsize == 0 then return {}, 0 end

    --  And generate the weight dictionary for passing to zunionstore.
    local j = 0
    local weights = new_tab((nsize * 2) + 1, 0)
    weights[nsize + 1] = "WEIGHTS"
    for i=1,n do
        local size = sizes[i]
        local key = keys[i]
        local idfv = idfs[i]
        if size then
            j = j + 1
            weights[j] = key
            weights[j + nsize + 1] = idfv
        end
    end

    -- Generate a temporary result storage key
    local temp_key = prefix ..'temp:'.. rstring.to_hex(rrandom.bytes(8))
    -- Actually perform the union to combine the scores.
    local known = r:zunionstore(temp_key, j, unpack(weights))
    -- Get the results.
    local ids = r:zrevrange(temp_key, offset, offset + count - 1, "WITHSCORES")
    -- Clean up after ourselves.
    r:del(temp_key)

    return ids, known
end


--- FIXME handle cursor based
function _M.destroy(self, redis)
    local db = redis or self.redis
    local pattern = self.prefix .. '*'
    local info = db:info('keyspace')
    local n = match(info, 'keys=([0-9]+)', 'jo')[1]
    local o = db:scan(0, 'match', pattern, 'count', n + 1)[2]
    local on = #o
    db:init_pipeline(on)
    for i = 1, on do
        db:del(o[i])
    end
    local a = db:commit_pipeline()
    return o, a
end


return _M
