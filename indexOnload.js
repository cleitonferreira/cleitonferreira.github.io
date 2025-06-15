function indexOnLoad() {

    //Filter cards
    if(window.location.hash) {
        var hash = window.location.hash.substring(1); //removes the # character
        filterHashTag(hash);
    }

    //Mansory
    resizeAllGridItems();
}

