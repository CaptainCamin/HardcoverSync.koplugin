local Book = require("hardcover/lib/book")

describe("Book", function()
  describe("currentRead", function()
    it("prefers the newest unfinished read with a recorded page", function()
      local reads = {
        { id = 1, finished_at = "2026-01-01", progress_pages = 400 },
        { id = 2, progress_pages = 250 },
        { id = 3 },
      }
      assert.are.equal(2, Book:currentRead(reads).id)
      reads[3].progress_pages = 0
      assert.are.equal(3, Book:currentRead(reads).id)
    end)

    it("otherwise prefers the newest unfinished read, then the newest read", function()
      local reads = { { id = 1 }, { id = 2, finished_at = "2026-01-01", progress_pages = 400 } }
      assert.are.equal(1, Book:currentRead(reads).id)
      reads[1].finished_at = "2025-01-01"
      assert.are.equal(2, Book:currentRead(reads).id)
      assert.is_nil(Book:currentRead({}))
    end)
  end)

  describe("parseIdentifiers", function()
    it("parses 10 character strings as isbn10", function()
      local identifiers = "asin:1234567890"
      local expected = {
        isbn_10 = "1234567890"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses 13 character strings as isbn13", function()
      local identifiers = "asin 13:1234567890123"
      local expected = {
        isbn_13 = "1234567890123"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses hardcover book and editions", function()
      local identifiers = [[
HARDCOVER:the-hobbit
HARDCOVER-EDITION:16193290
]]

      local expected = {
        book_slug = "the-hobbit",
        edition_id = "16193290"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("parses hardcover-slug", function()
      local identifiers = "HARDCOVER-SLUG:1984"
      local expected = {
        book_slug = "1984"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)

    it("prioritizes hardcover editions over isbn", function()
      local identifiers = [[
HARDCOVER:1234567890
HARDCOVER-EDITION:1234567890123
]]

      local expected = {
        book_slug = "1234567890",
        edition_id = "1234567890123"
      }
      assert.are.same(expected, Book:parseIdentifiers(identifiers))
    end)
  end)
end)
