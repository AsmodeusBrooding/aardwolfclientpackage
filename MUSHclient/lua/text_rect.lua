-- Bits of this code and ideas were borrowed and remixed from the MUSHclient community. https://www.mushclient.com/forum/?id=9385 and others.

require "wait"
require "copytable"
require "colors"
dofile (GetInfo(60) .. "aardwolf_colors.lua")

local function getHighlightColor(bg)
   local h, s, l = colors.rgb_string_to_hsl(string.format('#%06x', bg))
   if l >= 0.5 then
      bgr = {colors.hsl_to_rgb(h, s, l/2)}
      local buffer = "0x"
      for i,v in ipairs(bgr) do
         buffer = buffer..string.format("%02x",math.floor(v*255+0.5))
      end
      return tonumber(buffer)
   else
      return bg+0x444444
   end
end

TextRect = {
   hotspot_map = {}
}
TextRect_defaults = {
   raw_lines = {},
   wrapped_lines = {},
   max_lines = 1000,
   font_name = "Dina",
   font_size = 10,
   start_line = 1,
   display_start_line = 1,
   end_line = 1,
   display_end_line = 1,
   num_raw_lines = 0,
   num_wrapped_lines = 0,
   keepscrolling = "",
   padding = 5,
   background_color = 0x000000,
   highlight_color = getHighlightColor(0x000000)
}
TextRect_mt = { __index = TextRect }

function TextRect.new(window, name, left, top, right, bottom, max_lines, scrollable, background_color, padding, font_name, font_size, external_scroll_handler, call_on_select)
   new_tr = setmetatable(copytable.deep(TextRect_defaults), TextRect_mt)
   new_tr.id = "TextRect_"..window.."_"..name
   new_tr.window = window
   new_tr.name = name
   new_tr:configure(left, top, right, bottom, max_lines, scrollable, background_color, padding, font_name, font_size, external_scroll_handler, call_on_select)
   return new_tr
end

function TextRect:configure(left, top, right, bottom, max_lines, scrollable, background_color, padding, font_name, font_size, external_scroll_handler, call_on_select)
   self.scrollable = scrollable
   self.external_scroll_handler = external_scroll_handler
   self.call_on_select = call_on_select
   self.padding = padding or self.padding
   self.max_lines = max_lines or self.max_lines
   self.font_name = font_name or self.font_name
   self.font_size = font_size or self.font_size
   if background_color ~= self.background_color then
      self.background_color = background_color or self.background_color
      self.highlight_color = getHighlightColor(self.background_color)
   end
   self:setRect(left, top, right, bottom)
   self:loadFont(self.font_name, self.font_size)
end

function TextRect:loadFont(name, size)
   if (not self.font) or (name ~= self.font_name) or (size ~= self.font_size) then
      self.font = self.id.."_font"
      self.font_name = name
      self.font_size = size

      WindowFont(self.window, self.font, self.font_name, self.font_size, false, false, false, false, 0)
      self.line_height = WindowFontInfo(self.window, self.font, 1)
      self.rect_lines = math.floor(self.padded_height / self.line_height)
   end
end

-- Returns an array {start, end, text}
function TextRect:findURLs(text)
   local URLs = {}
   local start, position = 0, 0
   -- "rex" is a table supplied by MUSHclient for PCRE functionality.
   local re = rex.new("(?:https?://|mailto:)\\S*[\\w/=@#\\-\\?]")
   re:gmatch(text,
      function (link, _)
         start, position = string.find(text, link, position, true)
         table.insert(URLs, {start=start, stop=position, text=link})
      end
   )
   return URLs
end -- function findURL

function TextRect:addColorLine(line)
   self:addStyles(ColoursToStyles(line))
end

function TextRect:addStyles(styles)
   -- extract URLs so we can add our movespots later
   local urls = self:findURLs(strip_colours_from_styles(styles))

   -- pop the oldest line from our buffer if we're at capacity
   if self.num_raw_lines >= self.max_lines then
      table.remove(self.raw_lines, 1)
      self.num_raw_lines = self.num_raw_lines - 1
   end

   -- add to raw lines table
   table.insert(self.raw_lines, {[1]=styles, [2]=urls})
   self.num_raw_lines = self.num_raw_lines + 1

   -- add to wrapped lines table for display
   self:wrapLine(styles, urls, self.num_raw_lines)
end

function TextRect:doUpdateCallbacks()
   if self.update_callbacks then
      for _, cb in ipairs(self.update_callbacks) do
         local obj = cb[1]
         local func = cb[2]
         func(obj, self.display_start_line, self.rect_lines, self.num_wrapped_lines)
      end
   end
end

function TextRect:wrapLine(stylerun, rawURLs, raw_index)
   local available = self.padded_width
   local line_styles = {}
   local beginning = true
   local length = 0
   local styles = copytable.deep(stylerun)
   local urls = copytable.deep(rawURLs)

   local remove = table.remove
   local insert = table.insert
   local sub = string.sub
   local find = string.find

   -- Keep pulling out styles and trying to fit them on the current line
   while #styles > 0 do
      -- break off the next style
      local style = remove(styles, 1)

      -- make this handle forced newlines like in the flickoff social
      -- by splitting off and sticking the next part back into the
      -- styles list for the next pass
      foundbreak = false
      newline = find(style.text, "\n")
      if newline then
         insert(styles, 1, {text = sub(style.text, newline+1),
               length = style.length-newline+1,
               textcolour = style.textcolour,
               backcolour = style.backcolour}
         )
         -- we're leaving in the newline characters here because we need to be
         -- able to copy them. I'll clean up the buggy visual later when
         -- actually displaying the lines.
         style.length = newline
         style.text = sub(style.text, 1, newline)
         foundbreak = true
      end

      local whole_width = WindowTextWidth(self.window, self.font, style.text)
      local t_width = whole_width

      -- if it fits, copy whole style in
      if t_width <= available then
         insert(line_styles, style)
         length = length + style.length
         available = available - t_width
         if foundbreak then
            available = 0
         end
      else -- otherwise, have to split style
         -- look for spaces to break at
         local col = 2
         local fits = true
         local fit_col = nil
         while col < style.length do
            if sub(style.text, col, col) == " " then
               t_width = WindowTextWidth(self.window, self.font, sub(style.text, 1, col-1))
               if t_width > available then
                  break
               else
                  fit_col = col -- found a space where we can split
               end
            end
            col = col + 1
         end
         if not fit_col then -- no spaces available for split
            if available == self.padded_width then -- starts at the beginning of the line
               -- step backward from the last measured col
               while col > 1 do
                  t_width = WindowTextWidth(self.window, self.font, sub(style.text, 1, col))
                  if t_width <= available then
                     fit_col = col
                     break
                  end
                  col = col - 1
               end
            end
         end

         if fit_col then
            -- if we found a place to split, truncate the style and put the rest
            -- back into the styles list
            local style_left = copytable.shallow(style)
            style.text = sub(style.text, 1, fit_col)
            style.length = fit_col
            style_left.text = sub(style_left.text, fit_col + 1)
            style_left.length = style_left.length - fit_col
            insert(line_styles, style)
            insert(styles, 1, style_left)
            length = length + style.length
         else
            -- put the style back for the next line
            insert(styles, 1, style) -- put style back for the next line
         end -- if
         available = 0 -- now we need to wrap
      end -- if could/not fit whole thing in

      -- out of styles or out of room? add a line for what we have so far
      if #styles == 0 or available <= 0 then
         if self.num_wrapped_lines >= self.max_lines then
            -- if the history buffer is full then remove the oldest line
            remove(self.wrapped_lines, 1)
            self.num_wrapped_lines = self.num_wrapped_lines - 1
            self.start_line = math.max(1, self.start_line - 1)
            self.end_line = math.max(1, self.end_line - 1)
            self.display_start_line = math.max(1, self.display_start_line - 1)
            self.display_end_line = math.max(1, self.display_end_line - 1)
            if self.copy_start_line then
               self.copy_start_line = math.max(0, self.copy_start_line - 1)
               self.copy_end_line = math.max(self.copy_start_line, self.copy_end_line - 1)
            end
         end -- buffer full

         local line_urls = {}
         while urls[1] and urls[1].stop <= length do
            insert(line_urls, remove(urls, 1))
         end

         if urls[1] and urls[1].start < length then
            local url = copytable.deep(urls[1])
            url.stop = length + 1
            urls[1].stop = urls[1].stop-1
            urls[1].old = true
            insert(line_urls, url)
         end

         for i,v in ipairs(urls) do
            urls[i].start = urls[i].start - length
            urls[i].stop = urls[i].stop - length
            if urls[i].start <= 1 then
               urls[i].start = 1
               urls[i].stop = urls[i].stop+1
            end
         end

         -- scroll down if viewing the bottom
         if self.end_line == self.num_wrapped_lines then
            if self.end_line >= self.rect_lines then
               self.start_line = self.start_line + 1
               self.display_start_line = self.start_line
            end
            self.end_line = self.end_line + 1
            self.display_end_line = self.end_line
         end

         -- add new wrapped line component
         self.num_wrapped_lines = self.num_wrapped_lines + 1
         local raw_index_delta = self.num_wrapped_lines - raw_index
         table.insert(self.wrapped_lines, {[1]=line_styles, [2]=beginning, [3]=line_urls, [4]=raw_index_delta} )

         -- prep for next line
         available = self.padded_width
         line_styles = {}
         length = 0
         beginning = false
      end -- line full
   end -- while we still have styles left
end

function TextRect:clear()
   self.raw_lines = {}
   self.num_raw_lines = 0
   self:reWrapLines()
   self:draw()
end

function TextRect:debug()
   require "pairsbykeys"
   for k,v in pairsByKeys(self) do print(k, "--", v) end
end

function TextRect:reWrapLines()
   local raw_index = 0
   -- wrapLine messes with the start position, so track a temporary variable
   -- for start_line instead of self.start_line
   local start_line = math.max(1, self.display_start_line or 1) -- easier than finding where it goes negative

   if self.num_wrapped_lines ~= 0 then
      if self.wrapped_lines[start_line] == nil then
         print("ERROR: SEND THIS TO FIENDISH")
         self:debug()
      end
      raw_index = start_line - self.wrapped_lines[start_line][4]
   end

   self.wrapped_lines = {}
   self.num_wrapped_lines = 0
   for i, line in ipairs(self.raw_lines) do
      if i == raw_index then
         start_line = self.num_wrapped_lines + 1
      end
      self:wrapLine(line[1], line[2], i)
   end

   self.start_line = start_line
   self.start_line, self.end_line = self:snapToBottom()
   self.display_start_line = self.start_line
   self.display_end_line = self.end_line
end

function TextRect:drawLine(line, styles, backfill_start, backfill_end)
   local left = self.padded_left
   local top = self.padded_top + (line * self.line_height)
   if (backfill_start ~= nil and backfill_end ~= nil) then
      WindowRectOp(self.window, 2, backfill_start, top, backfill_end-1, top + self.line_height, self.highlight_color)
   end -- backfill
   if styles then
      utf8 = GetOption("utf_8")
      for _, v in ipairs(styles) do
         local t = v.text
         -- now clean up dangling newlines that cause block characters to show
         if string.sub(v.text, -1) == "\n" then
            t = string.sub(v.text, 1, -2)
         end
         left = left + WindowText(self.window, self.font, t, left, top, self.padded_right, self.padded_bottom, v.textcolour, utf8 and utils.utf8valid(t))
      end
   end
end

function TextRect:draw(cleanup_first, inside_callback)
   if cleanup_first ~= false then -- default true
      self:_deleteHyperlinks()
   end

   if not self.area_hotspot then
      self:initArea()
   end
   WindowRectOp(self.window, 2, self.left, self.top, self.right, self.bottom+1, self.background_color) -- clear
   local ax = nil
   local zx = nil
   local line_no_colors = ""
   local count = 0
   self.display_start_line, self.display_end_line = self:snapToBottom()
   if self.num_wrapped_lines >= 1 then
      for count = self.display_start_line, self.display_end_line do
         ax = nil
         zx = nil
         line_no_colors = strip_colours_from_styles(self.wrapped_lines[count][1])

         if self.keepscrolling == "" then
            -- create clickable links for urls
            for i,v in ipairs(self.wrapped_lines[count][3]) do
               local left = self.padded_left + WindowTextWidth(self.window, self.font, string.sub(line_no_colors, 1, v.start-1))
               local right = left + WindowTextWidth(self.window, self.font, string.sub(line_no_colors, v.start-1, v.stop-1))
               local top = self.padded_top + ((count - self.display_start_line) * self.line_height)-1
               local bottom = top + self.line_height
               local link_id = self:generateHotspotID(table.concat({v.text, " ", count, " ", v.start, " ", v.stop}))

               if not WindowHotspotInfo(self.window, link_id, 1) then
                  self.hyperlinks[link_id] = v.text
                  WindowAddHotspot(self.window, link_id, left, top, math.min(right, self.padded_right), bottom, "TextRect.linkHover", "TextRect.cancelLinkHover", "TextRect.clickUrl", "", "TextRect.mouseUp", "Right-click this URL if you want to open it:\n"..v.text, 1)
                  if self.scrollable then
                     WindowScrollwheelHandler(self.window, link_id, "TextRect.wheelMove")
                  elseif self.external_scroll_handler then
                     WindowScrollwheelHandler(self.window, link_id, self.external_scroll_handler)
                  end
               end
            end
         end

         -- create highlighting parameters when text is selected
         if self.copy_start_line ~= nil and self.copy_end_line ~= nil and count >= self.copy_start_line and count <= self.copy_end_line then
            ax = (
               (count == self.copy_start_line)
               and self.start_copying_x
               and math.min(self.start_copying_x, WindowTextWidth(self.window, self.font, line_no_colors) + self.padded_left)
               or self.padded_left
            )
            -- end of highlight for this line
            zx = math.min(
               self.padded_right,
               (
                  (count == self.copy_end_line)
                  and self.end_copying_x
                  and math.min(self.end_copying_x, WindowTextWidth(self.window, self.font, line_no_colors) + self.padded_left)
                  or (WindowTextWidth(self.window, self.font, line_no_colors) + self.padded_left)
               )
            )
         end
         self:drawLine(count - self.display_start_line, self.wrapped_lines[count][1], ax, zx )
      end
   end

   if not inside_callback then
      self:doUpdateCallbacks()
   end

   CallPlugin("abc1a0944ae4af7586ce88dc", "BufferedRepaint")
end

function TextRect:addUpdateCallback(object, callback)
   self.update_callbacks = self.update_callbacks or {}
   table.insert(self.update_callbacks, {object, callback})
end

function TextRect:snapToBottom()
   local start_line = math.max(1, math.min(self.start_line, self.num_wrapped_lines - self.rect_lines + 1))
   local end_line = math.max(1, math.min(start_line + self.rect_lines - 1, self.num_wrapped_lines))
   return start_line, end_line
end

function TextRect:setRect(left, top, right, bottom)
   self.left = left
   self.top = top
   self.right = right
   self.bottom = bottom + 1
   self.width = right-left
   self.height = bottom-top + 1
   self.padded_left = self.left + self.padding
   self.padded_top = self.top + self.padding
   self.padded_right = self.right - self.padding
   self.padded_bottom = self.bottom - self.padding
   self.padded_width = self.width - (2*self.padding)
   self.padded_height = self.height - (2*self.padding)
   if self.area_hotspot then
      WindowMoveHotspot(self.window, self.area_hotspot, self.left, self.top, self.right, self.bottom)
   end
   if self.line_height then
      self.rect_lines = math.floor(self.padded_height / self.line_height)
   end
end

function TextRect:getScroll()
   return self.start_line
end

function TextRect:setScroll(new_pos)
   self.start_line = math.max(1, math.min(new_pos, self.num_wrapped_lines - self.rect_lines + 1))
   self.end_line = math.min(self.start_line + self.rect_lines - 1, self.num_wrapped_lines)
   self.display_start_line = self.start_line
   self.display_end_line = self.end_line
   self:draw(true, true)
end

-- Scroll through the window contents line by line. Used when dragging out of text area
function TextRect:scroll()
   wait.make(function ()
      while self.keepscrolling == "up" or self.keepscrolling == "down" do
         if self.keepscrolling == "up" then
            if (self.start_line > 1) then
               self.start_line = self.start_line - 1
               self.end_line = self.end_line - 1
               self.display_start_line = self.start_line
               self.display_end_line = self.end_line
            end
         elseif self.keepscrolling == "down" then
            if (self.end_line < self.num_wrapped_lines) then
               self.start_line = self.start_line + 1
               self.end_line = self.end_line + 1
               self.display_start_line = self.start_line
               self.display_end_line = self.end_line
            end
         end
         self:draw(false)
         wait.time(0.01)
      end
   end)
end

function TextRect:initArea()
   --highlight, right click, scrolling
   self.area_hotspot = self:generateHotspotID("textarea")
   WindowAddHotspot(self.window, self.area_hotspot, self.left, self.top, self.right, self.top + self.height, "", "", "TextRect.mouseDown", "TextRect.cancelMouseDown", "TextRect.mouseUp", "", miniwin.cursor_ibeam, 0)
   WindowDragHandler(self.window, self.area_hotspot, "TextRect.dragMove", "TextRect.dragRelease", 0x10)
   if self.scrollable then
      WindowScrollwheelHandler(self.window, self.area_hotspot, "TextRect.wheelMove")
   elseif self.external_scroll_handler then
      WindowScrollwheelHandler(self.window, self.area_hotspot, self.external_scroll_handler)
   end
   self.hyperlinks = {}
end

function TextRect:_deleteHyperlinks()
   if self.hyperlinks then
      for k, v in pairs(self.hyperlinks) do
         WindowDeleteHotspot(self.window, k)
         TextRect.hotspot_map[k] = nil
      end
   end
   self.hyperlinks = {}
end

function TextRect:unInit()
   -- unload all hotspots
   if self.area_hotspot then
      TextRect.hotspot_map[self.area_hotspot] = nil
      WindowDeleteHotspot(self.window, self.area_hotspot)
      self.area_hotspot = nil
   end
   self:_deleteHyperlinks()
end

function TextRect.mouseDown(flags, hotspot_id)
   if (flags == miniwin.hotspot_got_lh_mouse) then
      local tr = TextRect.hotspot_map[hotspot_id]
      tr.temp_start_copying_x = WindowInfo(tr.window, 14)
      tr.start_copying_y = WindowInfo(tr.window, 15)
      tr.copy_start_windowline = math.floor((tr.start_copying_y - tr.top) / tr.line_height)
      tr.temp_start_line = tr.copy_start_windowline + tr.start_line
      tr.copy_start_line = nil
      tr.copy_end_line = nil
      tr.start_copying_x = nil
      tr.end_copying_x = nil
      tr.start_copying_pos = nil
      tr.end_copying_pos = nil
      tr:draw(false)
      if tr.call_on_select then
         tr.call_on_select(tr.copy_start_line, tr.copy_end_line, tr.start_copying_pos, tr.end_copying_pos, tr.start_copying_x, tr.end_copying_x)
      end
   end
end

function TextRect.mouseUp(flags, hotspot_id)
   local tr = TextRect.hotspot_map[hotspot_id]
   tr.keepscrolling = ""
   if bit.band(flags, miniwin.hotspot_got_rh_mouse) ~= 0 then
      tr:rightClickMenu(hotspot_id)
   else
      tr:draw()
   end
   return true
end

function TextRect.cancelMouseDown(flags, hotspot_id)
   local tr = TextRect.hotspot_map[hotspot_id]
   tr.keepscrolling = ""
   tr:draw()
end

function TextRect.dragMove(flags, hotspot_id)
   if bit.band(flags, miniwin.hotspot_got_lh_mouse) == 0 then return end -- only on left mouse button

   local tr = TextRect.hotspot_map[hotspot_id]
   tr.end_copying_x = WindowInfo(tr.window, 17) - WindowInfo(tr.window, 1)
   tr.end_copying_y = WindowInfo(tr.window, 18) - WindowInfo(tr.window, 2)
   local ypos = tr.end_copying_y
   tr.copy_end_windowline = math.floor((tr.end_copying_y - tr.top) / tr.line_height)
   tr.copy_end_line = tr.copy_end_windowline + tr.start_line
   tr.copy_start_line = tr.temp_start_line
   tr.start_copying_x = tr.temp_start_copying_x

   -- get the entire last line if we drag off the bottom
   if tr.copy_end_line <= tr.end_line then
      tr.end_copying_x = math.max(tr.left, math.min(tr.end_copying_x, tr.right))
   else
      tr.end_copying_x = tr.right
   end

   if not tr.copy_start_line then
      -- OS bug causing errors for me? hack around stupid mouse click tracking mess.
      -- It really shouldn't be possible to get here, ever, but what the hell, it happened.
      return
   end

   if (tr.copy_start_line > #tr.wrapped_lines) then
      tr.start_copying_x = tr.right
   end

   -- the user is selecting backwards, so reverse the start/end orders
   if tr.copy_end_line < tr.temp_start_line then
      local temp = tr.copy_end_line
      tr.copy_end_line = tr.copy_start_line
      tr.copy_start_line = temp
      temp = tr.end_copying_x
      tr.end_copying_x = tr.start_copying_x
      tr.start_copying_x = temp
   elseif (tr.copy_end_line == tr.copy_start_line) and (tr.end_copying_x < tr.start_copying_x) then
      local temp = tr.end_copying_x
      tr.end_copying_x = tr.start_copying_x
      tr.start_copying_x = temp
   end

   for copy_line = tr.copy_start_line, tr.copy_end_line do
      if (tr.wrapped_lines[copy_line] ~= nil) then
         local startpos = 0
         local endpos = 99999
         if (copy_line - tr.start_line + 1 > 0 and copy_line - tr.start_line < tr.rect_lines and copy_line - tr.start_line < #tr.wrapped_lines) then

            -- Clamp to character boundaries instead of selecting arbitrary pixel positions...

            -- Get the line without color codes so we can reference position to character
            local line_no_colors = strip_colours_from_styles(tr.wrapped_lines[copy_line][1])

            endpos = #line_no_colors

            -- Clamp the selection start position
            if copy_line == tr.copy_start_line then
               tr.start_copying_pos = 1
               for pos=1,#line_no_colors do
                  if (WindowTextWidth(tr.window, tr.font, string.sub(line_no_colors, 1, pos)) + tr.padded_left) > tr.start_copying_x then
                     tr.start_copying_x = WindowTextWidth(tr.window, tr.font, string.sub(line_no_colors, 1, pos-1)) + tr.padded_left
                     tr.start_copying_pos = pos
                     break
                  end
                  startpos = pos
               end
            end
            -- Clamp the selection end position
            if copy_line == tr.copy_end_line then
               endpos = 0
               tr.end_copying_pos = #line_no_colors + 1
               for pos=1,#line_no_colors do
                  if WindowTextWidth(tr.window, tr.font, string.sub(line_no_colors, 1, pos)) + tr.padded_left > tr.end_copying_x then
                     tr.end_copying_x = WindowTextWidth(tr.window, tr.font, string.sub(line_no_colors, 1, pos-1)) + tr.padded_left
                     tr.end_copying_pos = pos
                     break
                  end
                  endpos = pos
               end
            end
         end
      end -- if valid line
   end -- copying lines

   if tr.scrollable then
      -- Scroll if the mouse is dragged off the top or bottom
      if ypos < tr.top then
         if tr.keepscrolling ~= "up" then
            tr.keepscrolling = "up"
            tr:scroll()
         end
         return
      elseif ypos > tr.bottom then
         if tr.keepscrolling ~= "down" then
            tr.keepscrolling = "down"
            tr:scroll()
         end
         return
      else
         tr.keepscrolling = ""
      end
   end
   tr:draw(false)
   if tr.call_on_select then
      tr.call_on_select(tr.copy_start_line, tr.copy_end_line, tr.start_copying_pos, tr.end_copying_pos, tr.start_copying_x, tr.end_copying_x)
   end
end

function TextRect.dragRelease(flags, hotspot_id)
   local tr = TextRect.hotspot_map[hotspot_id]
   tr.copy_start_line = math.min(#tr.wrapped_lines, tr.copy_start_line or 0)
   tr.copy_end_line = math.min(#tr.wrapped_lines, tr.copy_end_line or 0)
   if tr.call_on_select then
      tr.call_on_select(tr.copy_start_line, tr.copy_end_line, tr.start_copying_pos, tr.end_copying_pos, tr.start_copying_x, tr.end_copying_x)
   end
end

function TextRect.wheelMove(flags, hotspot_id)
   local tr = TextRect.hotspot_map[hotspot_id]
   local delta = math.ceil(bit.shr(flags, 16) / 3)
   local line_delta = math.ceil(delta / tr.line_height)
   if bit.band(flags, miniwin.wheel_scroll_back) ~= 0 then
      -- down
      if tr.start_line < #tr.wrapped_lines - tr.rect_lines + 1 then
         tr.start_line = math.max(1, math.min(#tr.wrapped_lines - tr.rect_lines + 1, tr.start_line + line_delta))
         tr.end_line = math.min(#tr.wrapped_lines, tr.start_line + tr.rect_lines - 1)
         tr.display_start_line = tr.start_line
         tr.display_end_line = tr.end_line
         tr:draw()
      end
   else
      if tr.start_line > 1 then
         -- up
         tr.start_line = math.max(1, tr.start_line - line_delta)
         tr.end_line = math.min(#tr.wrapped_lines, tr.start_line + tr.rect_lines - 1)
         tr.display_start_line = tr.start_line
         tr.display_end_line = tr.end_line
         tr:draw()
      end -- if
   end
end

function TextRect.linkHover(flags, hotspot_id)
   if GetOption("underline_hyperlinks") == 0 then
      return
   end
   local tr = TextRect.hotspot_map[hotspot_id]
   local url = tr.hyperlinks[hotspot_id]
   local hotspots = WindowHotspotList(tr.window)
   for _, v in ipairs (hotspots) do
      if string.find(v, url, 1, true) then
         local left = WindowHotspotInfo(tr.window, v, 1)
         local right = WindowHotspotInfo(tr.window, v, 3)
         local bottom = WindowHotspotInfo(tr.window, v, 4) + 1
         WindowLine(tr.window, left, bottom, right, bottom, 0xffffff, 256, 1);
      end
   end
   CallPlugin("abc1a0944ae4af7586ce88dc", "BufferedRepaint")
end

function TextRect.cancelLinkHover(flags, hotspot_id)
   local tr = TextRect.hotspot_map[hotspot_id]
   local url = tr.hyperlinks[hotspot_id]

   if not string.find(WindowInfo(tr.window, 19), url, 1, true) then
      tr:draw(false)
   end
end

function TextRect:setExternalMenuFunction(menu_string_generator, menu_result_function)
   self.external_menu_string_generator = menu_string_generator
   self.external_menu_result_function = menu_result_function
end

function TextRect:rightClickMenu(hotspot_id)
   local menu_text = {}
   local menu_functions = {}

   if self.hyperlinks[hotspot_id] then
      table.insert(menu_text, "Browse URL: " .. self.hyperlinks[hotspot_id])
      table.insert(menu_text, "Copy URL to Clipboard")
      table.insert(menu_text, "-")
      table.insert(menu_functions, TextRect.browseUrl)
      table.insert(menu_functions, TextRect.copyUrl)
   end

   if (self.copy_start_line ~= nil) and (self.copy_end_line ~= nil) then
      table.insert(menu_text, "Copy Selected")
      table.insert(menu_text, "Copy Selected Without Colors")
      table.insert(menu_functions, TextRect.copy)
      table.insert(menu_functions, TextRect.copyPlain)
   end

   table.insert(menu_text, "Copy All")
   table.insert(menu_functions, TextRect.copyFull)

   local inner_count = #menu_functions

   if self.external_menu_string_generator and self.external_menu_result_function then
      local ems = self.external_menu_string_generator()
      if ems:sub(1,1) == "!" then
         ems = ems:sub(2)
      end

      table.insert(menu_text, "-")
      table.insert(menu_text, ems)
      table.insert(menu_functions, self.external_menu_result_function)
   end

   result = tonumber(
      WindowMenu (
         self.window,
         WindowInfo (self.window, 14), -- x coord
         WindowInfo (self.window, 15), -- y coord
         "!"..table.concat(menu_text, "|")
      )
   )

   if result then
      func = result
      if result > inner_count then
         result = result - inner_count
         func = inner_count + 1
      end
      menu_functions[func](self, hotspot_id, result)
   end
end

function TextRect:browseUrl(hotspot_id)
   local url = self.hyperlinks[hotspot_id]
   if url then
      OpenBrowser(url)
   end
end

function TextRect.clickUrl(flags, hotspot_id)
   if bit.band(flags, miniwin.hotspot_got_rh_mouse) ~= 0 then  -- only left-button
      return
   end
   local tr = TextRect.hotspot_map[hotspot_id]
   tr:browseUrl(hotspot_id)
end

function TextRect:serializeContents()
   require "serialize"
   local keys = {
      raw_lines = {},
      start_line = 1,
   }

   local contents = {}
   for k,v in pairs(keys) do
      contents[k] = self[k]
   end

   return serialize.save_simple(contents)
end

function TextRect:deserializeContents(contents)
   if (type(contents) == "string") and (contents ~= "") then
      local contents = loadstring("return "..contents)()
      if (type(contents) == "table") and contents.raw_lines and contents.start_line then
         self.raw_lines = contents.raw_lines
         self.num_raw_lines = #self.raw_lines
         self:reWrapLines()
         self:setScroll(contents.start_line)
      end
   end
end

function TextRect:copyAndNotify(text)
   ColourNote("cyan","","--------------------Copied to clipboard--------------------")
   ColourNote("yellow","", text)
   ColourNote("cyan","","-----------------------------------------------------------")
   SetClipboard(text)
end

function TextRect:copyUrl(hotspot_id)
   local url = self.hyperlinks[hotspot_id]
   if url then
      self:copyAndNotify(url)
   end
end

function TextRect:copyPlain()
   self:copyAndNotify(strip_colours(self:selected_text()))
end

function TextRect:copy()
   self:copyAndNotify(self:selected_text())
end

function TextRect:selected_text()
   selected_text = {}
   current_message = {}

   function store_message()
      if current_message[1] then
         -- end in white if line contains any other color
         for _,s in ipairs(current_message) do
            if s.textcolour then
               table.insert(current_message, {text="", textcolour=GetNormalColour(8)})
               break
            end
         end

         -- preserve the message and start the next one
         table.insert(selected_text, StylesToColours(current_message))
         current_message = {}
      end
   end

   for copy_line = self.copy_start_line, self.copy_end_line do
      if (self.wrapped_lines[copy_line] ~= nil) then
         local startpos = 0
         local endpos = 99999
         if copy_line == self.copy_start_line then
            startpos = self.start_copying_pos
         end
         if copy_line == self.copy_end_line then
            endpos = self.end_copying_pos - 1
         end

         if endpos > startpos then
            -- store current message when starting a new one
            if self.wrapped_lines[copy_line][2] then
               store_message()
            end
            -- add styles from this wrapped line to the current message
            for _, s in ipairs(TruncateStyles(self.wrapped_lines[copy_line][1], startpos, endpos)) do
               table.insert(current_message, s)
            end
         elseif (endpos == 0) and (startpos == 0) and (copy_line ~= self.copy_end_line) and (copy_line ~= self.copy_start_line) then
            table.insert(selected_text, "")
         end
      end
   end

   -- preserve the final message
   store_message()

   return table.concat(selected_text, "\n")
end

function TextRect:copyFull()
   local t = {}
   for _,line in ipairs(self.raw_lines) do
      table.insert(t, StylesToColours(line[1]))
   end
   SetClipboard(table.concat(t, WHITE_CODE.."\n")..WHITE_CODE)
   ColourNote("yellow","","All text copied to clipboard.")
end

function TextRect:generateHotspotID(id)
   local hotspot_id = self.id.."_hotspot_"..id
   TextRect.hotspot_map[hotspot_id] = self
   return hotspot_id
end

