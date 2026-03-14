return {
    "dhananjaylatkar/cscope_maps.nvim",
    dependencies = {
        "nvim-lua/plenary.nvim",
    },
    lazy = false,
    opts = {},
    config = function()
        -- 1. Setup the plugin
        require('cscope_maps').setup({
            disable_maps = true, -- We disable default maps to use your custom ones
            cscope = {
                exec = 'cscope',
                db_file = './cscope.out',
                build_cmd = 'bash scripts/generate_cscope.sh && cscope -b -1 -k',
            }
        })

        -- 2. Create a helper function to perform the search
        -- This grabs the word under cursor and runs the Cscope command
        local function cscope_search(operation)
            local word = vim.fn.expand("<cword>")
            vim.cmd('Cscope find ' .. operation .. ' ' .. word)
        end

        -- 3. Set the Keymaps
        -- I have corrected the 'operation' keys (s, g, c, etc) to match standard cscope behavior
        local map = vim.keymap.set

        map('n', '<leader>csf', function() cscope_search('f') end, { desc = 'Find File' })
        map('n', '<leader>cso', function() cscope_search('g') end, { desc = 'Find global definition' })
        map('n', '<leader>csc', function() cscope_search('c') end, { desc = 'Find callers of this function' })
        map('n', '<leader>csd', function() cscope_search('d') end, { desc = 'Find functions called by this' })
        map('n', '<leader>cse', function() cscope_search('e') end, { desc = 'Find egrep pattern' })
        
        -- Note: Standard cscope uses 's' for symbol, not 'u'
        map('n', '<leader>csu', function() cscope_search('s') end, { desc = 'Find C symbol' })
        
        -- Note: Standard cscope uses 't' for text string
        map('n', '<leader>cst', function() cscope_search('t') end, { desc = 'Find text string' })
    end,
}
