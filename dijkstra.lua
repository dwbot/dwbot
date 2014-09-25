dijkstra = {}

do
  -- standard heap implementation --------
  local function push (tbl, v)
    table.insert(tbl, v)
    local n = #tbl
    local i = math.floor(n / 2)
    local val = v.val
    -- push the value up the heap
    while i >= 1 do
      if tbl[i].val <= val then break end
      tbl[i], tbl[n] = tbl[n], tbl[i]
      n, i = i, math.floor(i / 2)
    end
  end
  
  local function pop (tbl)
    if #tbl <= 2 then
      return table.remove(tbl, 1)
    elseif #tbl > 2 then
      local result = tbl[1]
      tbl[1] = table.remove(tbl)
      local val = tbl[1].val
      -- push the value down the heap
      local n, i, j = #tbl, 1, 2
      while j <= n do
        local v2 = tbl[j].val
        if j < n then
          local v3 = tbl[j+1].val
          if v3 < v2 then
            v2 = v3
            j = j + 1
          end
        end
        if val <= v2 then break end
        tbl[i], tbl[j] = tbl[j], tbl[i]
        i, j = j, j*2
      end
      return result
    end
  end

  local dxs, dys = {1,0,-1,0}, {0,1,0,-1}
  local dirs = {"e", "s", "w", "n"}
  
  -- reverse dijkstra
  -- see http://www.roguebasin.com/index.php?title=The_Incredible_Power_of_Dijkstra_Maps
  local cached_result = nil
  local cached_param = nil

  function dijkstra.reverse_dijkstra (x1, y1, x2, y2, cost_fn, zone_ptr)
    local param = zone_ptr .. "," .. x2 .. "," .. y2
    if param == cached_param then
      return cached_result
    end

    local result = {}
    local queue = {}
    local dist = nil

    result[y2*200+x2] = 0
    push(queue, { val = 0, x = x2, y = y2 })
    while #queue > 0 do
      local v = pop(queue)
      if v.x == x1 and v.y == y1 and ((not dist) or v.val < dist) then
        dist = v.val
      elseif (not dist) or v.val < dist then
        for i=1,4 do
          local dx, dy = dxs[i], dys[i]
          local xn, yn = v.x+dx, v.y+dy
          local vn = cost_fn(xn, yn)
          if vn > 0 then
            vn = vn + v.val
            local k = yn*200+xn
            if (not result[k]) or result[k] > vn then
              result[k] = vn
              push(queue, { val = vn, x = xn, y = yn })
            end         -- result[k] > vn
          end           -- vn > 0
        end             -- 1,4
      else
        break
      end
    end

    cached_result = result
    cached_param = param
    return result    
  end
  
end

return dijkstra
