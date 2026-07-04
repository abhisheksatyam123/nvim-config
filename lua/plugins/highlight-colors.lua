return {
    "Mr-LLLLL/interestingwords.nvim",
    config = function()
        require("interestingwords").setup {
            colors = {
                '#ffb3ba', -- Pastel Red
                '#ffdfba', -- Pastel Peach
                '#ffffba', -- Pastel Yellow
                '#baffc9', -- Pastel Mint Green
                '#bae1ff', -- Pastel Baby Blue
                '#e8b4f8', -- Pastel Lilac
                '#ffc0cb', -- Pastel Pink
                '#a8e6cf', -- Pastel Green
                '#a0d2db', -- Pastel Teal
                '#d4b8f8', -- Pastel Purple
                '#f8c8dc', -- Pastel Rose Pink
                '#c9e4de', -- Pastel Sage Green
                '#ffcc99', -- Pastel Apricot
                '#a0c4ff', -- Pastel Light Blue
                '#c3b1e1', -- Pastel Lavender
                '#e8d5b7', -- Pastel Sand
                '#d4e2d4', -- Pastel Tea Green
                '#b5eae6', -- Pastel Pale Cyan
                '#f8a4b8', -- Pastel Blossom
                '#ff8a9e', -- Pastel Coral Pink
                '#fff5a0', -- Pastel Lemon Yellow
                '#b5e7a0', -- Pastel Olive Green
                '#89cff0', -- Pastel Sky Blue
                '#c8a2eb', -- Pastel Violet
                '#ffd93d', -- Pastel Golden Yellow
            },
            search_count = true,
            navigation = true,
            search_key = "gz",
            cancel_search_key = "<leader>c",
            color_key = "<leader>k",
            cancel_color_key = "<leader>K",
        }
    end
}
