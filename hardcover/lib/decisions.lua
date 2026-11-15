-- The questions waiting for the reader, gathered from every queue that can park one.
--
-- A queue takes part by defining decisions(user_id): a list of
--   { id, kind, key, book_id, user_book_id, title, describe(), resolve(choice) }
-- where describe() returns the same { title, rows } shape as SyncConflicts.describe
-- and resolve() applies the answer and returns true when it changed something.
--
-- Plain data and closures, no KOReader requires, so it runs under stock Lua in the
-- spec suite. Pending changes and the conflict picker both read this list, so a new
-- kind of conflict only has to teach its queue to describe and resolve it.

local Decisions = {}

-- Every queue's open questions, in a stable order by book then id.
function Decisions.list(queues)
  local out = {}
  for key, queue in pairs(queues or {}) do
    if key ~= "user_id" and type(queue) == "table" and type(queue.decisions) == "function" then
      local ok, list = pcall(queue.decisions, queue, queues.user_id)
      if ok and type(list) == "table" then
        for _, decision in ipairs(list) do
          if type(decision) == "table" and decision.resolve then
            out[#out + 1] = decision
          end
        end
      end
    end
  end
  table.sort(out, function(a, b)
    local a_book, b_book = tonumber(a.book_id) or 0, tonumber(b.book_id) or 0
    if a_book ~= b_book then return a_book < b_book end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

function Decisions.count(queues)
  return #Decisions.list(queues)
end

return Decisions
