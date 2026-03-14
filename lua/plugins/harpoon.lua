return {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim", "nvim-telescope/telescope.nvim" },
    config = function()
        local harpoon = require("harpoon")
        harpoon:setup()
        -- REQUIRED

        local function toggle_telescope(harpoon_files)
            local telescope = require("telescope")
            local conf = require("telescope.config").values
            local file_paths = {}
            for _, item in ipairs(harpoon_files.items) do
                table.insert(file_paths, item.value)
            end

            require("telescope.pickers").new({}, {
                prompt_title = "Harpoon",
                finder = require("telescope.finders").new_table({
                    results = file_paths,
                }),
                previewer = conf.file_previewer({}),
                sorter = conf.generic_sorter({}),
                attach_mappings = function(prompt_bufnr, map)
                    local state = require("telescope.actions.state")
                    map({"n", "i"}, "<C-d>", function()
                        local selected_entry = state.get_selected_entry()
                        if not selected_entry then return end
                        local current_picker = state.get_current_picker(prompt_bufnr)
                        
                        for _, item in ipairs(harpoon_files.items) do
                            if item.value == selected_entry.value then
                                local try_remove = function() harpoon_files:remove(item) end
                                pcall(try_remove)
                                break
                            end
                        end
                        
                        local new_paths = {}
                        for _, item in ipairs(harpoon_files.items) do
                            table.insert(new_paths, item.value)
                        end
                        
                        current_picker:refresh(
                            require("telescope.finders").new_table({
                                results = new_paths,
                            }),
                            { reset_prompt = false }
                        )
                    end)
                    return true
                end,
            }):find()
        end

        vim.keymap.set("n", "<leader>ha", function() toggle_telescope(harpoon:list()) end,
            { desc = "Open harpoon window" })

        vim.keymap.set("n", "<leader>he", function() harpoon.ui:toggle_quick_menu(harpoon:list()) end,
            { desc = "Open harpoon default menu" })

        vim.keymap.set("n", "<leader>hm", function() harpoon:list():add() end,
            { desc = "Add file to harpoon" })

        -- Basic navigation
        vim.keymap.set("n", "<leader>hn", function() harpoon:list():next() end, { desc = "Next harpoon" })
        vim.keymap.set("n", "<leader>hp", function() harpoon:list():prev() end, { desc = "Previous harpoon" })
    end
}
