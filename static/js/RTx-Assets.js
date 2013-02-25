jQuery(function() {
    jQuery("input[data-autocomplete]").each(function(){
        var input = jQuery(this);
        var what  = input.attr("data-autocomplete");
        var wants = input.attr("data-autocomplete-return");

        if (!what || !what.match(/^(Users|Groups)$/))
            return;

        input.autocomplete({
            source: RT.Config.WebPath + "/Helpers/Autocomplete/" + what
                    + (wants ? "?return=" + wants : "")
        });
    });
});
