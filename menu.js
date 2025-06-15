function filterHashTag(hashtag){
    
    var gridItems = document.getElementsByClassName("gridItem");
    for (var g = 0; g < gridItems.length; g++) {

        var inputs = gridItems[g].getElementsByTagName("input");
        for (var i = 0; i < inputs.length; i++) {
            if(inputs[i].name == "hashtags") {
                if (inputs[i].value != "")
                {
                    var hashtags = inputs[i].value.split(" ");
                    for (var h = 0; h < hashtags.length; h++) {
                        if(hashtags[h] == hashtag){
                            gridItems[g].style.display = "block";
                            break;
                        }
                        else{
                            gridItems[g].style.display = "none";
                        }
                    }
                }
            }
        }
    }

    resizeAllGridItems();
}