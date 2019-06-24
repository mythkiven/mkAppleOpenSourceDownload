function osw_tsort(table, column)
{
    String.prototype.trim = function() {
	return this.replace(/^\s+|\s+$/g,"");
    }
    asc = $('project-list').hasClassName('desc');
    arr = Array.prototype.slice.call(table.tBodies[0].rows);
    rows = arr.splice(0, arr.length);
    rows.sort(function(l,r) 
	      { 	
		  ltext = l.cells[column].textContent.trim();
		  rtext = r.cells[column].textContent.trim();
		  lname = l.cells[1].textContent.trim();
		  rname = r.cells[1].textContent.trim();
		  if (ltext == rtext) {
		      if (lname == rname) {
			  return 0;
		      }
		      return (lname > rname ? 1 : -1);
		  }
		  if (asc) {
		      return (ltext > rtext ? 1 : -1);
		  }
		  return (ltext > rtext ? -1 : 1); 
	      });
    rows.each(function(r,i) { table.tBodies[0].appendChild(r); });
    $('project-list').addClassName('sorted');    	
    if (asc) {
	$('project-list').addClassName('asc');
	$('project-list').removeClassName('desc');
    } else {
	$('project-list').removeClassName('asc');
	$('project-list').addClassName('desc');
    }
}

function toggle_release_list(id)
{
    listid = "release-list-" + id;
    hdrid = "list-header-" + id;
    if ($(listid).style.display == 'none') {
	Effect.BlindDown(listid, {duration: 0.5}); 
	$(hdrid).removeClassName('disc-arrow-closed');
	$(hdrid).addClassName('disc-arrow-open');
    } else {
	Effect.BlindUp(listid, {duration: 0.5}); 
	$(hdrid).addClassName('disc-arrow-closed');
	$(hdrid).removeClassName('disc-arrow-open');
    }
    return false;
}

function hide_release_list(id)
{
    listid = "release-list-" + id;
    hdrid = "list-header-" + id;
    $(listid).hide();
    $(hdrid).addClassName('disc-arrow-closed');
    $(hdrid).removeClassName('disc-arrow-open');
}