# Changelog

## [Unreleased]

### Added
* Model agnostic counterfactual explanations have been added.
* Shapelet forest counterfactual explanations has been refined.
* KNearestNeighbors counterfactual explanations has been refined.
* Synthetic generation of outlier detection datasets.
* IsolationShapeletForest has been added. A novel semi-supervised method for detecting
  time series outliers.
* Fast computation of scaled and unscaled dynamic time warping (using the UCRSuite algorithm).
* LB_Keogh lower bound and envelope.

### Changed

* `wildboar.datasets.install_repository` now installs a repository instead of a bundle
* Rename parameter `repository` of `load_dataset` to `bundle`
* Rename `Repository` to `Bundle`

## [v1.0.3]

### Added

* Added a counterfactual explainability module

## [v1.0]

### Fixed

* Stability

## [v0.3.4]

## Changed

* Complete rewrite of the shapelet tree representation to allow releasing GIL.
  The prediction of trees should be backwards compatible, i.e., trees fitted using
  the new versions are functionally equivalent to the old but with another internal
  representation.

## [v0.3.1]

### Fixed

* Improved caching of lower-bound for DTW 
  The DTW subsequence search implementation has been improved by caching
  DTW lower-bound information for repeated calls with the same
  subsequece. This slightly increases the memory requirement, but can
  give significantly improved performance under certain circumstances.
 
* Allow shapelet information to be extracted 
  A new attribute `ts_info` is added to `Shapelet` (which is accessible 
  from `tree.root_node_.shapelet`). `ts_info` returns a tuple
  `(ts_index, ts_start, length)` with information about the index (in 
  the `x` used to fit, `fit(x, y)`, the model) and the start position of 
  the shapelet. For a shapelet tree/forest fit on `x` the shapelet in a 
  particular node is given by `x[ts_index, ts_start:(ts_start + length)]`.
  
## [v0.3]

### Added
* Regression shapelet trees 
  A new type of shapelet trees has been added. 
  `wildboar.tree.ShapeletTreeRegressor` which allows for constructing shapelet
  trees used to predict real value outputs.

* Regression shapelet forest
  A new tyoe of shapelet forest has been added. 
  `wildboar.ensemble.ShapeletForestRegressor` which allows for constructing
  shapelet forests for predicting real value outputs.

### Fixes

 * a6f656d Fix bug for strided labels not correctly accounted for
 * 321a04d Remove unused property `unscaled_threshold`