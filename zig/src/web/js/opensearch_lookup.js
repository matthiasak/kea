(function () {
  var link = document.querySelector('link[rel~="search"][type="application/opensearchdescription+xml"][href]');
  return link ? link.href : null;
})();
